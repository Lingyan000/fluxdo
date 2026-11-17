#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "qjs_dart.h"
#include "quickjs.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
typedef CRITICAL_SECTION qjs_mutex_t;
#define qjs_mutex_init(m) InitializeCriticalSection(m)
#define qjs_mutex_lock(m) EnterCriticalSection(m)
#define qjs_mutex_unlock(m) LeaveCriticalSection(m)
#define qjs_mutex_destroy(m) DeleteCriticalSection(m)
typedef volatile LONG qjs_refcount_t;
#define qjs_refcount_inc(p) InterlockedIncrement(p)
#define qjs_refcount_dec(p) InterlockedDecrement(p)
typedef volatile LONG qjs_atomic_flag_t;
#define qjs_atomic_flag_exchange(p, v) InterlockedExchange((p), (v))
static SRWLOCK g_live_runtimes_lock = SRWLOCK_INIT;
#define qjs_live_runtimes_lock() AcquireSRWLockExclusive(&g_live_runtimes_lock)
#define qjs_live_runtimes_unlock() ReleaseSRWLockExclusive(&g_live_runtimes_lock)
#else
#include <pthread.h>
typedef pthread_mutex_t qjs_mutex_t;
#define qjs_mutex_init(m) pthread_mutex_init(m, NULL)
#define qjs_mutex_lock(m) pthread_mutex_lock(m)
#define qjs_mutex_unlock(m) pthread_mutex_unlock(m)
#define qjs_mutex_destroy(m) pthread_mutex_destroy(m)
typedef int qjs_refcount_t;
#define qjs_refcount_inc(p) __atomic_add_fetch(p, 1, __ATOMIC_RELAXED)
#define qjs_refcount_dec(p) __atomic_sub_fetch(p, 1, __ATOMIC_ACQ_REL)
typedef int qjs_atomic_flag_t;
#define qjs_atomic_flag_exchange(p, v) __atomic_exchange_n((p), (v), __ATOMIC_ACQ_REL)
static pthread_mutex_t g_live_runtimes_lock = PTHREAD_MUTEX_INITIALIZER;
#define qjs_live_runtimes_lock() pthread_mutex_lock(&g_live_runtimes_lock)
#define qjs_live_runtimes_unlock() pthread_mutex_unlock(&g_live_runtimes_lock)
#endif

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_STACK_ARGS 8

typedef union QJSValueOrAtom {
  JSValue val;
  JSAtom atom;
} QJSValueOrAtom;

struct QJSABIManagedPointerImpl {
  struct QJSABIManagedPointer base;
  struct QJSABIRuntime *rt;
  QJSValueOrAtom u;
  bool is_atom;
  struct QJSABIManagedPointerImpl *prev;
  struct QJSABIManagedPointerImpl *next;
};

struct QJSABIPreparedJavaScript {
  struct QJSABIRuntime *rt;
  JSValue func_obj;
  struct QJSABIPreparedJavaScript *prev;
  struct QJSABIPreparedJavaScript *next;
};

typedef struct QJSPendingFree {
  QJSValueOrAtom u;
  bool is_atom;
  struct QJSPendingFree *next;
} QJSPendingFree;

typedef struct QJSRejectionEvent {
  JSValue promise;
  JSValue reason;
  bool is_handled;
  struct QJSRejectionEvent *next;
} QJSRejectionEvent;

static void free_rejection_events(JSContext *ctx, QJSRejectionEvent *ev) {
  while (ev) {
    QJSRejectionEvent *next = ev->next;
    JS_FreeValue(ctx, ev->promise);
    JS_FreeValue(ctx, ev->reason);
    free(ev);
    ev = next;
  }
}

struct QJSABIRuntime {
  JSRuntime *rt;
  JSContext *ctx;
  JSValue last_js_error;
  char *last_native_exception;
  JSClassID host_object_class_id;
  JSClassID native_state_class_id;
  JSClassID host_function_class_id;
  struct QJSABIManagedPointerImpl *pointers_head;
  struct QJSABIPreparedJavaScript *prepared_head;
  // Guards pointers_head, prepared_head, pending_frees and is_released.
  // Never call into JS while holding it: JS finalizers may call into Dart,
  // which can wait for a GC whose NativeFinalizers wait for this mutex.
  qjs_mutex_t free_mutex;
  // One reference is owned by the runtime itself, one by every managed and
  // prepared pointer. The struct (and free_mutex) outlives JS_FreeRuntime
  // until the last reference is dropped, so finalizers can always lock it.
  qjs_refcount_t refcount;
  QJSPendingFree * volatile pending_frees;
  // Sandbox controls. deadline_us is only touched on the isolate's thread;
  // interrupt_requested may be set from any thread.
  uint64_t deadline_us;
  qjs_atomic_flag_t interrupt_requested;
  QJSABIPromiseRejectionTracker rejection_tracker;
  // While a module evaluates, rejections are held back until it is known
  // which of them belong to its own evaluation promise.
  int rejection_buffer_depth;
  QJSRejectionEvent *buffered_rejections;
  QJSABIModuleResolve module_resolve;
  QJSABIModuleLoad module_load;
  // Registry of live runtimes, guarded by g_live_runtimes_lock, so that
  // qjs_runtime_request_interrupt never touches a released runtime.
  uint64_t id;
  struct QJSABIRuntime *live_prev;
  struct QJSABIRuntime *live_next;
  void *temp_string_buf;
  JSAtom native_state_atom;
  bool microtask_queue;
  bool is_released;
};

// Runs pending jobs unless the embedder drains them itself. Returns -1 with
// a pending exception if a job fails (e.g. it was interrupted); the remaining
// jobs stay queued.
static int drain_jobs_if_needed(struct QJSABIRuntime *rt) {
  if (rt && !rt->microtask_queue && rt->rt) {
    JSContext *pctx;
    int ret;
    while ((ret = JS_ExecutePendingJob(rt->rt, &pctx)) > 0);
    if (ret < 0) return -1;
  }
  return 0;
}

static struct QJSABIRuntime *g_live_runtimes_head;
static uint64_t g_next_runtime_id = 1;

static void live_runtimes_add(struct QJSABIRuntime *rt) {
  qjs_live_runtimes_lock();
  rt->id = g_next_runtime_id++;
  rt->live_prev = NULL;
  rt->live_next = g_live_runtimes_head;
  if (g_live_runtimes_head) g_live_runtimes_head->live_prev = rt;
  g_live_runtimes_head = rt;
  qjs_live_runtimes_unlock();
}

static void live_runtimes_remove(struct QJSABIRuntime *rt) {
  qjs_live_runtimes_lock();
  if (rt->live_prev) {
    rt->live_prev->live_next = rt->live_next;
  } else if (g_live_runtimes_head == rt) {
    g_live_runtimes_head = rt->live_next;
  }
  if (rt->live_next) rt->live_next->live_prev = rt->live_prev;
  rt->live_prev = NULL;
  rt->live_next = NULL;
  qjs_live_runtimes_unlock();
}

static uint64_t monotonic_now_us(void) {
#ifdef _WIN32
  LARGE_INTEGER freq, counter;
  QueryPerformanceFrequency(&freq);
  QueryPerformanceCounter(&counter);
  return (uint64_t)(counter.QuadPart / freq.QuadPart) * 1000000u +
         (uint64_t)(counter.QuadPart % freq.QuadPart) * 1000000u / (uint64_t)freq.QuadPart;
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
#endif
}

// Polled by QuickJS every few thousand operations; must not call into Dart.
static int interrupt_handler(JSRuntime *js_rt, void *opaque) {
  (void)js_rt;
  struct QJSABIRuntime *rt = (struct QJSABIRuntime *)opaque;
  if (qjs_atomic_flag_exchange(&rt->interrupt_requested, 0)) return 1;
  return rt->deadline_us != 0 && monotonic_now_us() >= rt->deadline_us;
}

static void runtime_retain(struct QJSABIRuntime *rt) {
  qjs_refcount_inc(&rt->refcount);
}

static void runtime_unref(struct QJSABIRuntime *rt) {
  if (qjs_refcount_dec(&rt->refcount) == 0) {
    qjs_mutex_destroy(&rt->free_mutex);
    free(rt);
  }
}

// Must be called with free_mutex held and is_released == false.
static void push_pending_free_locked(struct QJSABIRuntime *rt, QJSValueOrAtom u, bool is_atom) {
  QJSPendingFree *pf = (QJSPendingFree *)malloc(sizeof(QJSPendingFree));
  if (pf) {
    pf->u = u;
    pf->is_atom = is_atom;
    pf->next = rt->pending_frees;
    rt->pending_frees = pf;
  }
}

static void free_pending_list(JSContext *ctx, QJSPendingFree *curr) {
  while (curr) {
    QJSPendingFree *next = curr->next;
    if (ctx) {
      if (curr->is_atom) {
        JS_FreeAtom(ctx, curr->u.atom);
      } else {
        JS_FreeValue(ctx, curr->u.val);
      }
    }
    free(curr);
    curr = next;
  }
}

static inline void flush_pending_frees(struct QJSABIRuntime *rt) {
  if (!rt || !rt->ctx || rt->is_released || !rt->pending_frees) return;

  qjs_mutex_lock(&rt->free_mutex);
  QJSPendingFree *curr = rt->pending_frees;
  rt->pending_frees = NULL;
  qjs_mutex_unlock(&rt->free_mutex);

  free_pending_list(rt->ctx, curr);
}

static void managed_pointer_invalidate(struct QJSABIManagedPointer *self) {
  if (!self) return;
  struct QJSABIManagedPointerImpl *impl = (struct QJSABIManagedPointerImpl *)self;
  struct QJSABIRuntime *rt = impl->rt;
  if (rt) {
    qjs_mutex_lock(&rt->free_mutex);
    if (!rt->is_released) {
      if (impl->prev) {
        impl->prev->next = impl->next;
      } else if (rt->pointers_head == impl) {
        rt->pointers_head = impl->next;
      }
      if (impl->next) {
        impl->next->prev = impl->prev;
      }
      impl->prev = NULL;
      impl->next = NULL;
      push_pending_free_locked(rt, impl->u, impl->is_atom);
    }
    qjs_mutex_unlock(&rt->free_mutex);
    impl->rt = NULL;
    runtime_unref(rt);
  }
  free(impl);
}

static const struct QJSABIManagedPointerVTable g_managed_vtable = {
  managed_pointer_invalidate
};

static void set_out_of_memory(struct QJSABIRuntime *rt) {
  free(rt->last_native_exception);
  rt->last_native_exception = strdup("out of memory");
}

// Takes ownership of val/atom. Returns NULL and records an "out of memory"
// native exception if the wrapper cannot be allocated.
static struct QJSABIManagedPointerImpl *create_managed(
  struct QJSABIRuntime *rt,
  JSValue val,
  JSAtom atom,
  bool is_atom
) {
  if (rt) flush_pending_frees(rt);
  struct QJSABIManagedPointerImpl *impl =
    (struct QJSABIManagedPointerImpl *)malloc(sizeof(struct QJSABIManagedPointerImpl));
  if (!impl) {
    if (rt && rt->ctx) {
      if (is_atom) {
        JS_FreeAtom(rt->ctx, atom);
      } else {
        JS_FreeValue(rt->ctx, val);
      }
      set_out_of_memory(rt);
    }
    return NULL;
  }
  impl->base.vtable = &g_managed_vtable;
  impl->rt = rt;
  if (is_atom) {
    impl->u.atom = atom;
  } else {
    impl->u.val = val;
  }
  impl->is_atom = is_atom;
  if (rt) {
    runtime_retain(rt);
    qjs_mutex_lock(&rt->free_mutex);
    impl->prev = NULL;
    impl->next = rt->pointers_head;
    if (rt->pointers_head) rt->pointers_head->prev = impl;
    rt->pointers_head = impl;
    qjs_mutex_unlock(&rt->free_mutex);
  } else {
    impl->prev = NULL;
    impl->next = NULL;
  }
  return impl;
}

#define create_managed_pointer(rt, val) create_managed((rt), (val), 0, false)
#define create_managed_atom(rt, atom) create_managed((rt), JS_UNDEFINED, (atom), true)

static inline uintptr_t make_error_ptr(enum QJSABIErrorCode err) {
  return ((uintptr_t)err << 2) | 1;
}

static inline bool is_error_ptr(uintptr_t ptr) {
  return (ptr & 1) != 0;
}

static inline enum QJSABIErrorCode get_error_from_ptr(uintptr_t ptr) {
  return (enum QJSABIErrorCode)(ptr >> 2);
}

static inline JSValue get_js_value(struct QJSABIManagedPointer *p) {
  if (!p) return JS_UNDEFINED;
  return ((struct QJSABIManagedPointerImpl *)p)->u.val;
}

static inline JSAtom get_js_atom(struct QJSABIManagedPointer *p) {
  if (!p) return 0;
  struct QJSABIManagedPointerImpl *impl = (struct QJSABIManagedPointerImpl *)p;
  return impl->is_atom ? impl->u.atom : JS_ValueToAtom(impl->rt->ctx, impl->u.val);
}

static void record_js_exception(struct QJSABIRuntime *rt) {
  JSValue exc = JS_GetException(rt->ctx);
  if (!JS_IsUndefined(rt->last_js_error)) {
    JS_FreeValue(rt->ctx, rt->last_js_error);
  }
  rt->last_js_error = exc;
}

static struct QJSABIValue return_js_error_val(struct QJSABIRuntime *rt) {
  record_js_exception(rt);
  struct QJSABIValue err;
  memset(&err, 0, sizeof(err));
  err.kind = QJSABIValueKindError;
  err.data.error = QJSABIErrorCodeJSError;
  return err;
}

static uintptr_t return_ptr_or_error(struct QJSABIRuntime *rt, JSValue val) {
  if (JS_IsException(val)) {
    record_js_exception(rt);
    return make_error_ptr(QJSABIErrorCodeJSError);
  }
  struct QJSABIManagedPointerImpl *impl = create_managed_pointer(rt, val);
  if (!impl) return make_error_ptr(QJSABIErrorCodeNativeException);
  return (uintptr_t)impl;
}

static uintptr_t return_void_or_error(struct QJSABIRuntime *rt, int ret) {
  if (ret < 0) {
    record_js_exception(rt);
    return make_error_ptr(QJSABIErrorCodeJSError);
  }
  return 0;
}

static uintptr_t return_bool_or_error(struct QJSABIRuntime *rt, int ret) {
  if (ret < 0) {
    record_js_exception(rt);
    return make_error_ptr(QJSABIErrorCodeJSError);
  }
  return (uintptr_t)(ret != 0 ? 4 : 0);
}

static struct QJSABIValue to_qjs_abi_value(struct QJSABIRuntime *rt, JSValue val) {
  struct QJSABIValue res;
  memset(&res, 0, sizeof(res));

  int tag = JS_VALUE_GET_NORM_TAG(val);
  switch (tag) {
    case JS_TAG_UNDEFINED:
      res.kind = QJSABIValueKindUndefined;
      break;
    case JS_TAG_NULL:
      res.kind = QJSABIValueKindNull;
      break;
    case JS_TAG_BOOL:
      res.kind = QJSABIValueKindBoolean;
      res.data.boolean = (JS_VALUE_GET_BOOL(val) != 0);
      break;
    case JS_TAG_INT:
      res.kind = QJSABIValueKindNumber;
      res.data.number = (double)JS_VALUE_GET_INT(val);
      break;
    case JS_TAG_FLOAT64:
      res.kind = QJSABIValueKindNumber;
      res.data.number = JS_VALUE_GET_FLOAT64(val);
      break;
    case JS_TAG_STRING:
    case JS_TAG_STRING_ROPE:
      res.kind = QJSABIValueKindString;
      res.data.pointer = (struct QJSABIManagedPointer *)create_managed_pointer(rt, val);
      break;
    case JS_TAG_SYMBOL:
      res.kind = QJSABIValueKindSymbol;
      res.data.pointer = (struct QJSABIManagedPointer *)create_managed_pointer(rt, val);
      break;
    case JS_TAG_BIG_INT:
    case JS_TAG_SHORT_BIG_INT:
      res.kind = QJSABIValueKindBigInt;
      res.data.pointer = (struct QJSABIManagedPointer *)create_managed_pointer(rt, val);
      break;
    case JS_TAG_OBJECT:
    case JS_TAG_FUNCTION_BYTECODE:
    case JS_TAG_MODULE:
      res.kind = QJSABIValueKindObject;
      res.data.pointer = (struct QJSABIManagedPointer *)create_managed_pointer(rt, val);
      break;
    case JS_TAG_EXCEPTION:
      res.kind = QJSABIValueKindError;
      res.data.error = QJSABIErrorCodeJSError;
      break;
    default:
      res.kind = QJSABIValueKindUndefined;
      break;
  }
  if ((res.kind & QJS_ABI_POINTER_MASK) && !res.data.pointer) {
    res.kind = QJSABIValueKindError;
    res.data.error = QJSABIErrorCodeNativeException;
  }
  return res;
}

static struct QJSABIValueOrError return_val_or_error(struct QJSABIRuntime *rt, JSValue val) {
  struct QJSABIValueOrError res;
  if (JS_IsException(val)) {
    res.value = return_js_error_val(rt);
  } else {
    res.value = to_qjs_abi_value(rt, val);
  }
  return res;
}

// Converts the result of a top-level call, after draining the jobs it queued.
// A failing job turns the whole call into an error, so it is not lost.
static struct QJSABIValue finish_top_level_call(struct QJSABIRuntime *rt, JSValue val) {
  if (JS_IsException(val)) return return_js_error_val(rt);
  if (drain_jobs_if_needed(rt) < 0) {
    JS_FreeValue(rt->ctx, val);
    return return_js_error_val(rt);
  }
  return to_qjs_abi_value(rt, val);
}

static JSValue from_qjs_abi_value(struct QJSABIRuntime *rt, const struct QJSABIValue *val) {
  if (!val) return JS_UNDEFINED;
  switch (val->kind) {
    case QJSABIValueKindUndefined:
      return JS_UNDEFINED;
    case QJSABIValueKindNull:
      return JS_NULL;
    case QJSABIValueKindBoolean:
      return JS_NewBool(rt->ctx, val->data.boolean);
    case QJSABIValueKindNumber:
      return JS_NewFloat64(rt->ctx, val->data.number);
    case QJSABIValueKindString:
    case QJSABIValueKindSymbol:
    case QJSABIValueKindBigInt:
    case QJSABIValueKindObject:
      return val->data.pointer ? JS_DupValue(rt->ctx, get_js_value(val->data.pointer)) : JS_UNDEFINED;
    default:
      return JS_UNDEFINED;
  }
}

static inline void release_value(struct QJSABIValue *val) {
  if (!val) return;
  if ((val->kind & QJS_ABI_POINTER_MASK) && val->data.pointer) {
    qjs_pointer_release(val->data.pointer);
    val->data.pointer = NULL;
  }
}

static inline void *get_opaque_safe(JSValueConst obj) {
  JSClassID cid = 0;
  return JS_GetAnyOpaque(obj, &cid);
}

// Host Object implementation

typedef struct QJSHostObjectBridge {
  void *user_data;
  struct QJSABIRuntime *rt;
  QJSABIHostObjectGet get_cb;
  QJSABIHostObjectSet set_cb;
  QJSABIHostObjectGetOwnKeys get_own_keys_cb;
  QJSABIHostObjectHas has_cb;
  QJSABIHostObjectRelease release_cb;
} QJSHostObjectBridge;

static void host_object_finalizer(JSRuntime *rt, JSValueConst val) {
  (void)rt;
  QJSHostObjectBridge *bridge = (QJSHostObjectBridge *)get_opaque_safe(val);
  if (bridge) {
    if (bridge->release_cb) bridge->release_cb(bridge->user_data);
    free(bridge);
  }
}

static void raise_abi_error(struct QJSABIRuntime *rt, JSContext *ctx, int errorCode) {
  if (errorCode == QJSABIErrorCodeJSError) {
    JSValue err = rt->last_js_error;
    rt->last_js_error = JS_UNDEFINED;
    if (!JS_IsUndefined(err)) {
      JS_Throw(ctx, err);
    } else {
      JS_ThrowPlainError(ctx, "JavaScript error");
    }
  } else {
    const char *msg = rt->last_native_exception;
    if (msg) {
      JS_ThrowPlainError(ctx, "%s", msg);
      free(rt->last_native_exception);
      rt->last_native_exception = NULL;
    } else {
      JS_ThrowPlainError(ctx, "<unknown native exception>");
    }
  }
}

static JSValue host_object_get_property(
  JSContext *ctx,
  JSValueConst obj,
  JSAtom atom,
  JSValueConst receiver
) {
  (void)ctx; (void)receiver;
  QJSHostObjectBridge *bridge = (QJSHostObjectBridge *)get_opaque_safe(obj);
  if (bridge && bridge->get_cb) {
    struct QJSABIPropNameID propNameId = {
      .pointer = (struct QJSABIManagedPointer *)create_managed_atom(bridge->rt, JS_DupAtom(bridge->rt->ctx, atom))
    };
    if (!propNameId.pointer) return JS_ThrowOutOfMemory(ctx);
    struct QJSABIValueOrError res = bridge->get_cb(bridge->user_data, bridge->rt, propNameId);
    qjs_pointer_release(propNameId.pointer);
    if (res.value.kind == QJSABIValueKindError) {
      raise_abi_error(bridge->rt, ctx, res.value.data.error);
      return JS_EXCEPTION;
    }
    JSValue out = from_qjs_abi_value(bridge->rt, &res.value);
    release_value(&res.value);
    return out;
  }
  return JS_UNDEFINED;
}

static int host_object_set_property(
  JSContext *ctx,
  JSValueConst obj,
  JSAtom atom,
  JSValueConst value,
  JSValueConst receiver,
  int flags
) {
  (void)ctx; (void)receiver; (void)flags;
  QJSHostObjectBridge *bridge = (QJSHostObjectBridge *)get_opaque_safe(obj);
  if (bridge && bridge->set_cb) {
    struct QJSABIPropNameID propNameId = {
      .pointer = (struct QJSABIManagedPointer *)create_managed_atom(bridge->rt, JS_DupAtom(bridge->rt->ctx, atom))
    };
    if (!propNameId.pointer) {
      JS_ThrowOutOfMemory(ctx);
      return -1;
    }
    struct QJSABIValue abiVal = to_qjs_abi_value(bridge->rt, JS_DupValue(bridge->rt->ctx, value));
    struct QJSABIVoidOrError res = bridge->set_cb(bridge->user_data, bridge->rt, propNameId, &abiVal);
    qjs_pointer_release(propNameId.pointer);
    release_value(&abiVal);
    if (is_error_ptr(res.void_or_error)) {
      raise_abi_error(bridge->rt, ctx, (int)get_error_from_ptr(res.void_or_error));
      return -1;
    }
    return 1;
  }
  return 0;
}

// A host object owns the keys its has callback accepts or, without one, the
// keys its getOwnKeys callback returns. Returns 1 if `atom` is one of them, 0 if not, -1 with a pending exception.
static int host_object_has_own_key(JSContext *ctx, QJSHostObjectBridge *bridge, JSAtom atom) {
  if (!bridge) return 0;
  if (bridge->has_cb) {
    struct QJSABIPropNameID name = {
      .pointer = (struct QJSABIManagedPointer *)create_managed_atom(bridge->rt, JS_DupAtom(ctx, atom))
    };
    if (!name.pointer) {
      JS_ThrowOutOfMemory(ctx);
      return -1;
    }
    struct QJSABIBoolOrError res = bridge->has_cb(bridge->user_data, bridge->rt, name);
    qjs_pointer_release(name.pointer);
    if (is_error_ptr(res.bool_or_error)) {
      raise_abi_error(bridge->rt, ctx, (int)get_error_from_ptr(res.bool_or_error));
      return -1;
    }
    return (res.bool_or_error >> 2) != 0;
  }
  if (!bridge->get_own_keys_cb) return 0;
  struct QJSABIPropNameIDListPtrOrError keysRes = bridge->get_own_keys_cb(bridge->user_data, bridge->rt);
  if (is_error_ptr(keysRes.ptr_or_error)) {
    raise_abi_error(bridge->rt, ctx, (int)get_error_from_ptr(keysRes.ptr_or_error));
    return -1;
  }
  struct QJSABIPropNameIDList *list = (struct QJSABIPropNameIDList *)keysRes.ptr_or_error;
  if (!list) return 0;
  int found = 0;
  for (size_t i = 0; i < list->size; i++) {
    if (get_js_atom(list->props[i].pointer) == atom) {
      found = 1;
      break;
    }
  }
  if (list->vtable && list->vtable->release) list->vtable->release(list);
  return found;
}

static int host_object_has_property(JSContext *ctx, JSValueConst obj, JSAtom atom) {
  return host_object_has_own_key(ctx, (QJSHostObjectBridge *)get_opaque_safe(obj), atom);
}

// Needed for Object.keys, for-in and JSON.stringify: QuickJS asks it whether
// each key returned by get_own_property_names is enumerable.
static int host_object_get_own_property(
  JSContext *ctx,
  JSPropertyDescriptor *desc,
  JSValueConst obj,
  JSAtom atom
) {
  QJSHostObjectBridge *bridge = (QJSHostObjectBridge *)get_opaque_safe(obj);
  int found = host_object_has_own_key(ctx, bridge, atom);
  if (found <= 0 || !desc) return found;

  JSValue value = host_object_get_property(ctx, obj, atom, obj);
  if (JS_IsException(value)) return -1;
  desc->flags = JS_PROP_ENUMERABLE | JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE;
  desc->value = value;
  desc->getter = JS_UNDEFINED;
  desc->setter = JS_UNDEFINED;
  return 1;
}

static int host_object_get_own_property_names(
  JSContext *ctx,
  JSPropertyEnum **ptab,
  uint32_t *plen,
  JSValueConst obj
) {
  QJSHostObjectBridge *bridge = (QJSHostObjectBridge *)get_opaque_safe(obj);
  if (bridge && bridge->get_own_keys_cb) {
    struct QJSABIPropNameIDListPtrOrError keysRes = bridge->get_own_keys_cb(bridge->user_data, bridge->rt);
    if (is_error_ptr(keysRes.ptr_or_error)) {
      raise_abi_error(bridge->rt, ctx, (int)get_error_from_ptr(keysRes.ptr_or_error));
      *ptab = NULL;
      *plen = 0;
      return -1;
    }
    struct QJSABIPropNameIDList *list = (struct QJSABIPropNameIDList *)keysRes.ptr_or_error;
    if (list) {
      JSPropertyEnum *tab = (JSPropertyEnum *)js_malloc(ctx, sizeof(JSPropertyEnum) * (list->size > 0 ? list->size : 1));
      if (!tab) {
        if (list->vtable && list->vtable->release) list->vtable->release(list);
        *ptab = NULL;
        *plen = 0;
        return -1;
      }
      for (size_t i = 0; i < list->size; i++) {
        tab[i].is_enumerable = true;
        tab[i].atom = JS_DupAtom(ctx, get_js_atom(list->props[i].pointer));
      }
      *ptab = tab;
      *plen = (uint32_t)list->size;
      if (list->vtable && list->vtable->release) list->vtable->release(list);
      return 0;
    }
  }
  *ptab = NULL;
  *plen = 0;
  return 0;
}

static const JSClassExoticMethods g_host_object_exotic = {
  .get_own_property = host_object_get_own_property,
  .get_property = host_object_get_property,
  .set_property = host_object_set_property,
  .has_property = host_object_has_property,
  .get_own_property_names = host_object_get_own_property_names,
};

// Native State

typedef struct QJSNativeStateBridge {
  void *user_data;
  QJSABINativeStateRelease release_cb;
} QJSNativeStateBridge;

static void native_state_finalizer(JSRuntime *rt, JSValueConst val) {
  (void)rt;
  QJSNativeStateBridge *b = (QJSNativeStateBridge *)get_opaque_safe(val);
  if (b) {
    if (b->release_cb) b->release_cb(b->user_data);
    free(b);
  }
}

// Host Function

typedef struct QJSHostFunctionBridge {
  void *user_data;
  struct QJSABIRuntime *rt;
  QJSABIHostFunctionCall call_cb;
  QJSABIHostFunctionRelease release_cb;
} QJSHostFunctionBridge;


static void host_function_finalizer(JSRuntime *rt, JSValueConst val) {
  (void)rt;
  QJSHostFunctionBridge *b = (QJSHostFunctionBridge *)get_opaque_safe(val);
  if (b) {
    if (b->release_cb) b->release_cb(b->user_data);
    free(b);
  }
}

static JSValue host_function_call(
  JSContext *ctx,
  JSValueConst this_val,
  int argc,
  JSValueConst *argv,
  int magic,
  JSValue *func_data
) {
  (void)magic;
  QJSHostFunctionBridge *b = (QJSHostFunctionBridge *)get_opaque_safe(func_data[0]);
  if (!b || !b->call_cb) return JS_UNDEFINED;

  struct QJSABIValue this_arg = to_qjs_abi_value(b->rt, JS_DupValue(b->rt->ctx, this_val));
  struct QJSABIValue stack_args[MAX_STACK_ARGS];
  struct QJSABIValue *args = (argc <= MAX_STACK_ARGS)
    ? stack_args
    : (struct QJSABIValue *)calloc(argc, sizeof(struct QJSABIValue));
  if (!args) {
    release_value(&this_arg);
    return JS_ThrowOutOfMemory(ctx);
  }

  for (int i = 0; i < argc; i++) {
    args[i] = to_qjs_abi_value(b->rt, JS_DupValue(b->rt->ctx, argv[i]));
  }

  struct QJSABIValueOrError res = b->call_cb(b->user_data, b->rt, &this_arg, args, argc);

  for (int i = 0; i < argc; i++) release_value(&args[i]);
  if (args != stack_args) free(args);
  release_value(&this_arg);

  if (res.value.kind == QJSABIValueKindError) {
    raise_abi_error(b->rt, ctx, res.value.data.error);
    return JS_EXCEPTION;
  }
  JSValue out = from_qjs_abi_value(b->rt, &res.value);
  release_value(&res.value);
  return out;
}

// Runtime lifecycle & execution

static JSValue js_disabled_eval(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
  (void)this_val; (void)argc; (void)argv;
  return JS_ThrowTypeError(ctx, "eval is disabled");
}

static JSValue js_disabled_function_constructor(
  JSContext *ctx,
  JSValueConst new_target,
  int argc,
  JSValueConst *argv
) {
  (void)new_target; (void)argc; (void)argv;
  return JS_ThrowTypeError(ctx, "Function constructor is disabled");
}

// Replaces the constructor reachable through `proto.constructor` with one
// that throws. It keeps `proto` as its prototype, so `instanceof` still works.
static JSValue disable_function_constructor(JSContext *ctx, JSValueConst proto, const char *name) {
  JSValue ctor = JS_NewCFunction2(
    ctx, js_disabled_function_constructor, name, 1, JS_CFUNC_constructor_or_func, 0
  );
  JS_DefinePropertyValueStr(ctx, ctor, "prototype", JS_DupValue(ctx, proto), 0);
  JS_DefinePropertyValueStr(
    ctx, proto, "constructor", JS_DupValue(ctx, ctor), JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE
  );
  return ctor;
}

// Every function constructor compiles source code like eval does, so with
// eval disabled they must go too. Besides the global Function, they are
// reachable through the prototypes of async, generator and async generator
// functions.
static void disable_function_constructors(JSContext *ctx, JSValueConst global) {
  JSValue function_ctor = JS_GetPropertyStr(ctx, global, "Function");
  JSValue function_proto = JS_GetPropertyStr(ctx, function_ctor, "prototype");
  JS_SetPropertyStr(ctx, global, "Function", disable_function_constructor(ctx, function_proto, "Function"));
  JS_FreeValue(ctx, function_proto);
  JS_FreeValue(ctx, function_ctor);

  static const char protos_src[] =
    "[Object.getPrototypeOf(async function () {}),"
    " Object.getPrototypeOf(function* () {}),"
    " Object.getPrototypeOf(async function* () {})]";
  static const char *const names[] = { "AsyncFunction", "GeneratorFunction", "AsyncGeneratorFunction" };
  JSValue protos = JS_Eval(ctx, protos_src, sizeof(protos_src) - 1, "<init>", JS_EVAL_TYPE_GLOBAL);
  for (uint32_t i = 0; i < 3 && !JS_IsException(protos); i++) {
    JSValue proto = JS_GetPropertyUint32(ctx, protos, i);
    JS_FreeValue(ctx, disable_function_constructor(ctx, proto, names[i]));
    JS_FreeValue(ctx, proto);
  }
  JS_FreeValue(ctx, protos);
}

struct QJSABIRuntime *qjs_runtime_create(struct QJSABIRuntimeConfig config) {
  struct QJSABIRuntime *rt = (struct QJSABIRuntime *)calloc(1, sizeof(struct QJSABIRuntime));
  if (!rt) return NULL;

  rt->rt = JS_NewRuntime();
  if (!rt->rt) { free(rt); return NULL; }

  if (config.memory_limit > 0) {
    JS_SetMemoryLimit(rt->rt, config.memory_limit);
  }
  if (config.max_stack_size > 0) {
    JS_SetMaxStackSize(rt->rt, config.max_stack_size);
  }
  if (config.gc_threshold > 0) {
    JS_SetGCThreshold(rt->rt, config.gc_threshold);
  }

  rt->ctx = JS_NewContext(rt->rt);
  if (!rt->ctx) { JS_FreeRuntime(rt->rt); free(rt); return NULL; }

  JS_AddIntrinsicBigInt(rt->ctx);
  rt->last_js_error = JS_UNDEFINED;

  JSValue ns_sym = JS_NewPrivateSymbol(rt->ctx, "native_state");
  rt->native_state_atom = JS_ValueToAtom(rt->ctx, ns_sym);
  JS_FreeValue(rt->ctx, ns_sym);

  JSValue global = JS_GetGlobalObject(rt->ctx);

  if (!config.enable_eval) {
    JS_SetPropertyStr(rt->ctx, global, "eval", JS_NewCFunction(rt->ctx, js_disabled_eval, "eval", 1));
    disable_function_constructors(rt->ctx, global);
  }
  if (!config.es6_proxy) {
    JSAtom proxy_atom = JS_NewAtom(rt->ctx, "Proxy");
    JS_DeleteProperty(rt->ctx, global, proxy_atom, 0);
    JS_FreeAtom(rt->ctx, proxy_atom);
  }
  JS_FreeValue(rt->ctx, global);

  JS_NewClassID(rt->rt, &rt->host_object_class_id);
  JSClassDef host_class_def = {
    .class_name = "HostObject",
    .finalizer = host_object_finalizer,
    .exotic = (JSClassExoticMethods *)&g_host_object_exotic,
  };
  JS_NewClass(rt->rt, rt->host_object_class_id, &host_class_def);

  JS_NewClassID(rt->rt, &rt->native_state_class_id);
  JSClassDef state_class_def = {
    .class_name = "NativeState",
    .finalizer = native_state_finalizer,
  };
  JS_NewClass(rt->rt, rt->native_state_class_id, &state_class_def);

  JS_NewClassID(rt->rt, &rt->host_function_class_id);
  JSClassDef func_class_def = {
    .class_name = "HostFunctionData",
    .finalizer = host_function_finalizer,
  };
  JS_NewClass(rt->rt, rt->host_function_class_id, &func_class_def);

  qjs_mutex_init(&rt->free_mutex);
  rt->refcount = 1;
  rt->pending_frees = NULL;
  rt->microtask_queue = config.microtask_queue;
  JS_SetInterruptHandler(rt->rt, interrupt_handler, rt);
  live_runtimes_add(rt);
  return rt;
}

void qjs_free(void *ptr) {
  free(ptr);
}

void qjs_runtime_release(struct QJSABIRuntime *rt) {
  if (!rt) return;
  live_runtimes_remove(rt);

  // Only detach the lists under the lock. Freeing JS values can run JS
  // finalizers that call into Dart, and doing that with free_mutex held
  // deadlocks against NativeFinalizers running during a GC.
  qjs_mutex_lock(&rt->free_mutex);
  if (rt->is_released) {
    qjs_mutex_unlock(&rt->free_mutex);
    return;
  }

  struct QJSABIManagedPointerImpl *curr = rt->pointers_head;
  while (curr) {
    struct QJSABIManagedPointerImpl *next = curr->next;
    // The impl stays owned by its Dart finalizer, which may free it as soon
    // as the lock is released, so copy the value out now.
    push_pending_free_locked(rt, curr->u, curr->is_atom);
    curr->prev = NULL;
    curr->next = NULL;
    curr = next;
  }
  rt->pointers_head = NULL;

  struct QJSABIPreparedJavaScript *pcurr = rt->prepared_head;
  while (pcurr) {
    struct QJSABIPreparedJavaScript *pnext = pcurr->next;
    QJSValueOrAtom u = { .val = pcurr->func_obj };
    push_pending_free_locked(rt, u, false);
    pcurr->prev = NULL;
    pcurr->next = NULL;
    pcurr = pnext;
  }
  rt->prepared_head = NULL;

  QJSPendingFree *pfree = rt->pending_frees;
  rt->pending_frees = NULL;
  rt->is_released = true;
  qjs_mutex_unlock(&rt->free_mutex);

  free_pending_list(rt->ctx, pfree);

  free_rejection_events(rt->ctx, rt->buffered_rejections);
  rt->buffered_rejections = NULL;

  if (!JS_IsUndefined(rt->last_js_error)) {
    JS_FreeValue(rt->ctx, rt->last_js_error);
    rt->last_js_error = JS_UNDEFINED;
  }
  free(rt->last_native_exception);
  rt->last_native_exception = NULL;

  if (rt->temp_string_buf) {
    if (rt->ctx) JS_FreeCStringUTF16(rt->ctx, (const uint16_t *)rt->temp_string_buf);
    rt->temp_string_buf = NULL;
  }
  if (rt->native_state_atom != JS_ATOM_NULL) {
    if (rt->ctx) JS_FreeAtom(rt->ctx, rt->native_state_atom);
    rt->native_state_atom = JS_ATOM_NULL;
  }
  if (rt->ctx) {
    JS_FreeContext(rt->ctx);
    rt->ctx = NULL;
  }
  if (rt->rt) {
    JS_FreeRuntime(rt->rt);
    rt->rt = NULL;
  }
  runtime_unref(rt);
}

// Sandbox controls

// Dart isolate 会在事件间切换系统线程；每次进入脚本命令前重设栈顶，保留栈限额。
void qjs_runtime_update_stack_top(struct QJSABIRuntime *rt) {
  JS_UpdateStackTop(rt->rt);
}

void qjs_runtime_set_deadline(struct QJSABIRuntime *rt, uint64_t timeout_us) {
  uint64_t deadline = monotonic_now_us() + timeout_us;
  // 0 means "no deadline", and an overflow means "never".
  rt->deadline_us = deadline < timeout_us ? 0 : (deadline == 0 ? 1 : deadline);
}

void qjs_runtime_clear_deadline(struct QJSABIRuntime *rt) {
  rt->deadline_us = 0;
}

uint64_t qjs_runtime_get_id(struct QJSABIRuntime *rt) {
  return rt->id;
}

bool qjs_runtime_request_interrupt(struct QJSABIRuntime *rt, uint64_t id) {
  bool found = false;
  qjs_live_runtimes_lock();
  for (struct QJSABIRuntime *curr = g_live_runtimes_head; curr; curr = curr->live_next) {
    if (curr == rt && curr->id == id) {
      qjs_atomic_flag_exchange(&curr->interrupt_requested, 1);
      found = true;
      break;
    }
  }
  qjs_live_runtimes_unlock();
  return found;
}

_Static_assert(sizeof(struct QJSABIMemoryUsage) == sizeof(JSMemoryUsage),
               "QJSABIMemoryUsage must mirror JSMemoryUsage");

struct QJSABIMemoryUsage qjs_runtime_get_memory_usage(struct QJSABIRuntime *rt) {
  JSMemoryUsage usage;
  JS_ComputeMemoryUsage(rt->rt, &usage);
  struct QJSABIMemoryUsage res;
  memcpy(&res, &usage, sizeof(res));
  return res;
}

static void promise_rejection_tracker(
  JSContext *ctx,
  JSValueConst promise,
  JSValueConst reason,
  bool is_handled,
  void *opaque
) {
  struct QJSABIRuntime *rt = (struct QJSABIRuntime *)opaque;
  if (!rt->rejection_tracker) return;
  if (rt->rejection_buffer_depth > 0) {
    // A rejection handled before the module finishes evaluating, like its
    // own evaluation promise, is not reported at all.
    if (is_handled) {
      for (QJSRejectionEvent **link = &rt->buffered_rejections; *link; link = &(*link)->next) {
        QJSRejectionEvent *ev = *link;
        if (!ev->is_handled && JS_VALUE_GET_PTR(ev->promise) == JS_VALUE_GET_PTR(promise)) {
          *link = ev->next;
          ev->next = NULL;
          free_rejection_events(ctx, ev);
          return;
        }
      }
    }
    QJSRejectionEvent *ev = (QJSRejectionEvent *)malloc(sizeof(QJSRejectionEvent));
    if (ev) {
      ev->promise = JS_DupValue(ctx, promise);
      ev->reason = JS_DupValue(ctx, reason);
      ev->is_handled = is_handled;
      ev->next = NULL;
      QJSRejectionEvent **tail = &rt->buffered_rejections;
      while (*tail) tail = &(*tail)->next;
      *tail = ev;
      return;
    }
  }
  struct QJSABIValue abi_promise = to_qjs_abi_value(rt, JS_DupValue(ctx, promise));
  struct QJSABIValue abi_reason = to_qjs_abi_value(rt, JS_DupValue(ctx, reason));
  rt->rejection_tracker(rt, abi_promise, abi_reason, is_handled);
}

// Once no module is evaluating any more, reports the held back rejections in
// order.
static void end_rejection_buffer(struct QJSABIRuntime *rt) {
  if (--rt->rejection_buffer_depth > 0) return;

  QJSRejectionEvent *ev = rt->buffered_rejections;
  rt->buffered_rejections = NULL;
  while (ev) {
    QJSRejectionEvent *next = ev->next;
    if (rt->rejection_tracker) {
      // The tracker receives owned references.
      rt->rejection_tracker(
        rt,
        to_qjs_abi_value(rt, ev->promise),
        to_qjs_abi_value(rt, ev->reason),
        ev->is_handled
      );
    } else {
      JS_FreeValue(rt->ctx, ev->promise);
      JS_FreeValue(rt->ctx, ev->reason);
    }
    free(ev);
    ev = next;
  }
}

void qjs_runtime_set_promise_rejection_tracker(
  struct QJSABIRuntime *rt,
  QJSABIPromiseRejectionTracker tracker
) {
  rt->rejection_tracker = tracker;
  JS_SetHostPromiseRejectionTracker(rt->rt, tracker ? promise_rejection_tracker : NULL, rt);
}

void qjs_runtime_run_gc(struct QJSABIRuntime *rt) {
  flush_pending_frees(rt);
  JS_RunGC(rt->rt);
}

// Modules

static char *module_normalize(
  JSContext *ctx,
  const char *base_name,
  const char *name,
  void *opaque
) {
  struct QJSABIRuntime *rt = (struct QJSABIRuntime *)opaque;
  struct QJSABIValueOrError res = rt->module_resolve(rt, name, base_name);
  if (res.value.kind == QJSABIValueKindError) {
    raise_abi_error(rt, ctx, res.value.data.error);
    return NULL;
  }
  JSValue val = from_qjs_abi_value(rt, &res.value);
  release_value(&res.value);
  if (!JS_IsString(val)) {
    JS_FreeValue(ctx, val);
    JS_ThrowTypeError(ctx, "module resolver must return a string");
    return NULL;
  }
  const char *str = JS_ToCString(ctx, val);
  JS_FreeValue(ctx, val);
  if (!str) return NULL;
  char *out = js_strdup(ctx, str);
  JS_FreeCString(ctx, str);
  return out;
}

// Returns a QJSABIImportType, or -1 with a pending exception.
static int module_import_type(JSContext *ctx, JSValueConst attributes) {
  if (!JS_IsObject(attributes)) return QJSABIImportTypeJavaScript;
  JSValue type = JS_GetPropertyStr(ctx, attributes, "type");
  if (JS_IsException(type)) return -1;
  if (JS_IsUndefined(type)) return QJSABIImportTypeJavaScript;
  const char *str = JS_ToCString(ctx, type);
  JS_FreeValue(ctx, type);
  if (!str) return -1;
  int res;
  if (strcmp(str, "json") == 0) {
    res = QJSABIImportTypeJSON;
  } else if (strcmp(str, "text") == 0) {
    res = QJSABIImportTypeText;
  } else {
    JS_ThrowTypeError(ctx, "unsupported import type '%s'", str);
    res = -1;
  }
  JS_FreeCString(ctx, str);
  return res;
}

static int module_check_attributes(JSContext *ctx, void *opaque, JSValueConst attributes) {
  (void)opaque;
  JSPropertyEnum *tab;
  uint32_t len;
  if (JS_GetOwnPropertyNames(ctx, &tab, &len, attributes, JS_GPN_ENUM_ONLY | JS_GPN_STRING_MASK)) {
    return -1;
  }
  int ret = 0;
  for (uint32_t i = 0; i < len && ret == 0; i++) {
    const char *key = JS_AtomToCString(ctx, tab[i].atom);
    if (!key) {
      ret = -1;
    } else {
      if (strcmp(key, "type") != 0) {
        JS_ThrowSyntaxError(ctx, "import attribute '%s' is not supported", key);
        ret = -1;
      }
      JS_FreeCString(ctx, key);
    }
  }
  JS_FreePropertyEnum(ctx, tab, len);
  if (ret == 0 && module_import_type(ctx, attributes) < 0) ret = -1;
  return ret;
}

// Compiles `source`, which must be NUL-terminated, and resolves its imports.
// Returns the module value or JS_EXCEPTION.
static JSValue compile_module(JSContext *ctx, const char *source, size_t length, const char *name) {
  JSValue val = JS_Eval(ctx, source, length, name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
  if (JS_IsException(val)) return val;
  JSValue meta = JS_GetImportMeta(ctx, (JSModuleDef *)JS_VALUE_GET_PTR(val));
  if (JS_IsException(meta)) {
    JS_FreeValue(ctx, val);
    return JS_EXCEPTION;
  }
  JS_DefinePropertyValueStr(ctx, meta, "url", JS_NewString(ctx, name), JS_PROP_C_W_E);
  JS_FreeValue(ctx, meta);
  return val;
}

// The private value of an exports module is [name0, value0, name1, ...].
static int exports_module_init(JSContext *ctx, JSModuleDef *m) {
  JSValue exports = JS_GetModulePrivateValue(ctx, m);
  int64_t len = 0;
  int ret = JS_GetLength(ctx, exports, &len);
  for (int64_t i = 0; ret == 0 && i + 1 < len; i += 2) {
    JSValue key = JS_GetPropertyInt64(ctx, exports, i);
    const char *name = JS_ToCString(ctx, key);
    JS_FreeValue(ctx, key);
    if (!name) {
      ret = -1;
      break;
    }
    ret = JS_SetModuleExport(ctx, m, name, JS_GetPropertyInt64(ctx, exports, i + 1));
    JS_FreeCString(ctx, name);
  }
  JS_FreeValue(ctx, exports);
  JS_SetModulePrivateValue(ctx, m, JS_UNDEFINED);
  return ret;
}

// Takes ownership of `obj`. Its properties are read up front: once the module
// exists it cannot be removed, so nothing may fail after creating it.
static JSModuleDef *create_exports_module(JSContext *ctx, const char *name, JSValue obj) {
  JSPropertyEnum *tab;
  uint32_t len;
  if (JS_GetOwnPropertyNames(ctx, &tab, &len, obj, JS_GPN_ENUM_ONLY | JS_GPN_STRING_MASK)) {
    JS_FreeValue(ctx, obj);
    return NULL;
  }
  JSValue exports = JS_NewArray(ctx);
  bool failed = JS_IsException(exports);
  for (uint32_t i = 0; i < len && !failed; i++) {
    JSValue value = JS_GetProperty(ctx, obj, tab[i].atom);
    failed = JS_IsException(value) ||
      JS_SetPropertyInt64(ctx, exports, 2 * (int64_t)i, JS_AtomToString(ctx, tab[i].atom)) < 0 ||
      JS_SetPropertyInt64(ctx, exports, 2 * (int64_t)i + 1, value) < 0;
  }
  JS_FreeValue(ctx, obj);

  JSModuleDef *m = failed ? NULL : JS_NewCModule(ctx, name, exports_module_init);
  for (uint32_t i = 0; m && i < len; i++) {
    const char *export_name = JS_AtomToCString(ctx, tab[i].atom);
    if (export_name) {
      JS_AddModuleExport(ctx, m, export_name);
      JS_FreeCString(ctx, export_name);
    }
  }
  JS_FreePropertyEnum(ctx, tab, len);
  if (m) {
    JS_SetModulePrivateValue(ctx, m, exports);
  } else {
    JS_FreeValue(ctx, exports);
  }
  return m;
}

static JSModuleDef *module_loader(
  JSContext *ctx,
  const char *name,
  void *opaque,
  JSValueConst attributes
) {
  struct QJSABIRuntime *rt = (struct QJSABIRuntime *)opaque;
  int type = module_import_type(ctx, attributes);
  if (type < 0) return NULL;

  struct QJSABIValueOrError res = rt->module_load(rt, name, (enum QJSABIImportType)type);
  if (res.value.kind == QJSABIValueKindError) {
    raise_abi_error(rt, ctx, res.value.data.error);
    return NULL;
  }
  JSValue val = from_qjs_abi_value(rt, &res.value);
  release_value(&res.value);

  if (JS_IsString(val)) {
    size_t length;
    const char *source = JS_ToCStringLen(ctx, &length, val);
    JS_FreeValue(ctx, val);
    if (!source) return NULL;
    JSValue module = compile_module(ctx, source, length, name);
    JS_FreeCString(ctx, source);
    if (JS_IsException(module)) return NULL;
    // The context keeps the module alive.
    JSModuleDef *m = (JSModuleDef *)JS_VALUE_GET_PTR(module);
    JS_FreeValue(ctx, module);
    return m;
  }
  if (JS_IsObject(val)) return create_exports_module(ctx, name, val);

  JS_FreeValue(ctx, val);
  JS_ThrowTypeError(ctx, "module loader must return a string or an object");
  return NULL;
}

void qjs_runtime_set_module_loader(
  struct QJSABIRuntime *rt,
  QJSABIModuleResolve resolve,
  QJSABIModuleLoad load
) {
  rt->module_resolve = resolve;
  rt->module_load = load;
  if (resolve && load) {
    JS_SetModuleLoaderFunc2(rt->rt, module_normalize, module_loader, module_check_attributes, rt);
  } else {
    JS_SetModuleLoaderFunc2(rt->rt, NULL, NULL, NULL, NULL);
  }
}

struct QJSABIValueOrError qjs_runtime_evaluate_module(
  struct QJSABIRuntime *rt,
  const uint8_t *utf8_source,
  size_t source_length,
  const char *name,
  struct QJSABIValue *out_promise
) {
  memset(out_promise, 0, sizeof(*out_promise));
  out_promise->kind = QJSABIValueKindUndefined;
  struct QJSABIValueOrError res;

  JSValue module = compile_module(
    rt->ctx, (const char *)utf8_source, source_length, name ? name : "<module>"
  );
  if (JS_IsException(module)) {
    res.value = return_js_error_val(rt);
    return res;
  }
  JSModuleDef *m = (JSModuleDef *)JS_VALUE_GET_PTR(module);

  // A module that throws rejects its evaluation promise before anything can
  // handle it, which would be reported as an unhandled rejection.
  rt->rejection_buffer_depth++;
  JSValue promise = JS_EvalFunction(rt->ctx, module);
  if (JS_IsException(promise)) {
    res.value = return_js_error_val(rt);
    end_rejection_buffer(rt);
    return res;
  }
  JS_PromiseMarkAsHandled(rt->ctx, promise);
  end_rejection_buffer(rt);

  JSValue ns = JS_GetModuleNamespace(rt->ctx, m);
  if (JS_IsException(ns)) {
    JS_FreeValue(rt->ctx, promise);
    res.value = return_js_error_val(rt);
    return res;
  }
  if (drain_jobs_if_needed(rt) < 0) {
    JS_FreeValue(rt->ctx, promise);
    JS_FreeValue(rt->ctx, ns);
    res.value = return_js_error_val(rt);
    return res;
  }
  *out_promise = to_qjs_abi_value(rt, promise);
  res.value = to_qjs_abi_value(rt, ns);
  return res;
}

// Promises

enum QJSABIPromiseState qjs_promise_get_state(
  struct QJSABIRuntime *rt,
  struct QJSABIObject promise
) {
  return (enum QJSABIPromiseState)JS_PromiseState(rt->ctx, get_js_value(promise.pointer));
}

struct QJSABIValue qjs_promise_get_result(
  struct QJSABIRuntime *rt,
  struct QJSABIObject promise
) {
  return to_qjs_abi_value(rt, JS_PromiseResult(rt->ctx, get_js_value(promise.pointer)));
}

struct QJSABIVoidOrError qjs_promise_then(
  struct QJSABIRuntime *rt,
  struct QJSABIObject promise,
  struct QJSABIFunction on_fulfilled,
  struct QJSABIFunction on_rejected
) {
  struct QJSABIVoidOrError res;
  JSValue derived = JS_PromiseThen(
    rt->ctx,
    get_js_value(promise.pointer),
    get_js_value(on_fulfilled.pointer),
    get_js_value(on_rejected.pointer)
  );
  if (JS_IsException(derived)) {
    res.void_or_error = return_void_or_error(rt, -1);
    return res;
  }
  JS_FreeValue(rt->ctx, derived);
  // A settled promise queues its reactions right away.
  res.void_or_error = return_void_or_error(rt, drain_jobs_if_needed(rt));
  return res;
}

struct QJSABIObject qjs_runtime_get_global_object(struct QJSABIRuntime *rt) {
  struct QJSABIObject res = {
    .pointer = (struct QJSABIManagedPointer *)create_managed_pointer(rt, JS_GetGlobalObject(rt->ctx))
  };
  return res;
}

struct QJSABIValue qjs_evaluate_javascript(
  struct QJSABIRuntime *rt,
  const uint8_t *script,
  size_t script_len,
  const char *source_url
) {
  JSValue val = JS_Eval(rt->ctx, (const char *)script, script_len, source_url ? source_url : "<eval>", JS_EVAL_TYPE_GLOBAL);
  return finish_top_level_call(rt, val);
}

struct QJSABIPreparedJavaScriptOrError qjs_runtime_prepared_javascript_create(
  struct QJSABIRuntime *rt,
  const uint8_t *utf8_source,
  size_t source_length,
  const char *source_url
) {
  JSValue func_obj = JS_Eval(
    rt->ctx,
    (const char *)utf8_source,
    source_length,
    source_url ? source_url : "<eval>",
    JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY
  );

  struct QJSABIPreparedJavaScriptOrError res;
  if (JS_IsException(func_obj)) {
    record_js_exception(rt);
    res.ptr_or_error = make_error_ptr(QJSABIErrorCodeJSError);
    return res;
  }

  struct QJSABIPreparedJavaScript *prep =
    (struct QJSABIPreparedJavaScript *)malloc(sizeof(struct QJSABIPreparedJavaScript));
  if (!prep) {
    JS_FreeValue(rt->ctx, func_obj);
    res.ptr_or_error = make_error_ptr(QJSABIErrorCodeNativeException);
    return res;
  }
  runtime_retain(rt);
  prep->rt = rt;
  prep->func_obj = func_obj;
  qjs_mutex_lock(&rt->free_mutex);
  prep->prev = NULL;
  prep->next = rt->prepared_head;
  if (rt->prepared_head) rt->prepared_head->prev = prep;
  rt->prepared_head = prep;
  qjs_mutex_unlock(&rt->free_mutex);
  res.ptr_or_error = (uintptr_t)prep;
  return res;
}

struct QJSABIValueOrError qjs_runtime_prepared_javascript_evaluate(
  struct QJSABIRuntime *rt,
  struct QJSABIPreparedJavaScript *prepared
) {
  if (!prepared) {
    struct QJSABIValueOrError res;
    res.value.kind = QJSABIValueKindError;
    res.value.data.error = QJSABIErrorCodeNativeException;
    return res;
  }
  JSValue result = JS_EvalFunction(rt->ctx, JS_DupValue(rt->ctx, prepared->func_obj));
  struct QJSABIValueOrError res = { .value = finish_top_level_call(rt, result) };
  return res;
}

void qjs_preparedjavascript_release(struct QJSABIPreparedJavaScript *prepared) {
  if (!prepared) return;
  // May run from a NativeFinalizer on a GC thread, so the value is only
  // queued here and freed by the mutator in flush_pending_frees.
  struct QJSABIRuntime *rt = prepared->rt;
  if (rt) {
    qjs_mutex_lock(&rt->free_mutex);
    if (!rt->is_released) {
      if (prepared->prev) {
        prepared->prev->next = prepared->next;
      } else if (rt->prepared_head == prepared) {
        rt->prepared_head = prepared->next;
      }
      if (prepared->next) {
        prepared->next->prev = prepared->prev;
      }
      prepared->prev = NULL;
      prepared->next = NULL;
      QJSValueOrAtom u = { .val = prepared->func_obj };
      push_pending_free_locked(rt, u, false);
    }
    qjs_mutex_unlock(&rt->free_mutex);
    prepared->rt = NULL;
    runtime_unref(rt);
  }
  free(prepared);
}

bool qjs_runtime_drain_microtasks(struct QJSABIRuntime *rt, int max_microtasks_hint) {
  JSContext *pctx;
  int count = 0;
  while (max_microtasks_hint < 0 || count < max_microtasks_hint) {
    int err = JS_ExecutePendingJob(rt->rt, &pctx);
    if (err < 0) {
      record_js_exception(rt);
      return false;
    }
    if (err == 0) return true;
    count++;
  }
  return true;
}

struct QJSABIValueOrError qjs_value_create_from_json_utf8(
  struct QJSABIRuntime *rt,
  const uint8_t *json_bytes,
  size_t length
) {
  return return_val_or_error(rt, JS_ParseJSON(rt->ctx, (const char *)json_bytes, length, "<json>"));
}

uint64_t qjs_value_get_unique_id(struct QJSABIRuntime *rt, struct QJSABIValue val) {
  (void)rt;
  if ((val.kind & QJS_ABI_POINTER_MASK) && val.data.pointer) {
    return (uint64_t)(uintptr_t)JS_VALUE_GET_PTR(get_js_value(val.data.pointer));
  }
  // Primitives: mix the kind with the payload bits. Casting the double
  // directly would be undefined for NaN and out-of-range values.
  uint64_t bits = 0;
  if (val.kind == QJSABIValueKindNumber) {
    memcpy(&bits, &val.data.number, sizeof(bits));
  } else if (val.kind == QJSABIValueKindBoolean) {
    bits = val.data.boolean ? 1 : 0;
  }
  return (uint64_t)(uint32_t)val.kind ^ bits;
}

struct QJSABIValueOrError qjs_object_from_id(struct QJSABIRuntime *rt, uint64_t id) {
  // NativeFinalizers unlink and free list entries concurrently, so walk the
  // list under the lock. Wrap the result after unlocking: creating a managed
  // pointer takes the same lock.
  JSValue found = JS_NULL;
  qjs_mutex_lock(&rt->free_mutex);
  struct QJSABIManagedPointerImpl *curr = rt->pointers_head;
  while (curr) {
    if (!curr->is_atom && JS_VALUE_GET_TAG(curr->u.val) == JS_TAG_OBJECT &&
        (uint64_t)(uintptr_t)JS_VALUE_GET_PTR(curr->u.val) == id) {
      found = JS_DupValue(rt->ctx, curr->u.val);
      break;
    }
    curr = curr->next;
  }
  qjs_mutex_unlock(&rt->free_mutex);
  struct QJSABIValueOrError res = { .value = to_qjs_abi_value(rt, found) };
  return res;
}

// Runtime error handling

void qjs_runtime_set_js_error_value(struct QJSABIRuntime *rt, struct QJSABIValue error_value) {
  if (!JS_IsUndefined(rt->last_js_error)) JS_FreeValue(rt->ctx, rt->last_js_error);
  rt->last_js_error = from_qjs_abi_value(rt, &error_value);
}

void qjs_runtime_set_native_exception_message(struct QJSABIRuntime *rt, const char *message) {
  free(rt->last_native_exception);
  rt->last_native_exception = message ? strdup(message) : NULL;
}

struct QJSABIValue qjs_runtime_get_and_clear_js_error_value(struct QJSABIRuntime *rt) {
  JSValue err = rt->last_js_error;
  rt->last_js_error = JS_UNDEFINED;
  return to_qjs_abi_value(rt, err);
}

char *qjs_runtime_get_and_clear_native_exception_message(struct QJSABIRuntime *rt) {
  char *msg = rt->last_native_exception;
  rt->last_native_exception = NULL;
  return msg;
}

// Memory management

void qjs_pointer_release(struct QJSABIManagedPointer *ptr) {
  if (ptr && ptr->vtable && ptr->vtable->invalidate) {
    ptr->vtable->invalidate(ptr);
  }
}

void qjs_pointer_release_safe(struct QJSABIManagedPointer *ptr) {
  qjs_pointer_release(ptr);
}

void qjs_register_pointer(struct QJSABIRuntime *rt, struct QJSABIManagedPointer *ptr) {
  (void)rt; (void)ptr;
}

struct QJSABIManagedPointer *qjs_managed_pointer_clone(
  struct QJSABIRuntime *rt,
  struct QJSABIManagedPointer *ptr
) {
  if (!ptr) return NULL;
  struct QJSABIManagedPointerImpl *impl = (struct QJSABIManagedPointerImpl *)ptr;
  if (impl->is_atom) {
    return (struct QJSABIManagedPointer *)create_managed_atom(rt, JS_DupAtom(rt->ctx, impl->u.atom));
  } else {
    return (struct QJSABIManagedPointer *)create_managed_pointer(rt, JS_DupValue(rt->ctx, impl->u.val));
  }
}

bool qjs_managed_pointer_strict_equals(
  struct QJSABIRuntime *rt,
  struct QJSABIManagedPointer *a,
  struct QJSABIManagedPointer *b
) {
  if (a == b) return true;
  if (!a || !b) return false;
  struct QJSABIManagedPointerImpl *implA = (struct QJSABIManagedPointerImpl *)a;
  struct QJSABIManagedPointerImpl *implB = (struct QJSABIManagedPointerImpl *)b;
  if (implA->is_atom || implB->is_atom) {
    return get_js_atom(a) == get_js_atom(b);
  }
  return JS_IsStrictEqual(rt->ctx, implA->u.val, implB->u.val) != 0;
}

// Objects

struct QJSABIObjectOrError qjs_object_create(struct QJSABIRuntime *rt) {
  struct QJSABIObjectOrError res = { .ptr_or_error = return_ptr_or_error(rt, JS_NewObject(rt->ctx)) };
  return res;
}

// Returns JS_ATOM_NULL with a pending exception if the key cannot be
// converted (e.g. its toString() throws).
static JSAtom abi_value_to_atom(struct QJSABIRuntime *rt, const struct QJSABIValue *key) {
  JSValue key_val = from_qjs_abi_value(rt, key);
  JSAtom atom = JS_ValueToAtom(rt->ctx, key_val);
  JS_FreeValue(rt->ctx, key_val);
  return atom;
}

struct QJSABIValue qjs_object_get_property_from_value(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIValue key
) {
  JSAtom atom = abi_value_to_atom(rt, &key);
  if (atom == JS_ATOM_NULL) return return_js_error_val(rt);

  JSValue res = JS_GetProperty(rt->ctx, get_js_value(obj.pointer), atom);
  JS_FreeAtom(rt->ctx, atom);
  if (JS_IsException(res)) return return_js_error_val(rt);
  return to_qjs_abi_value(rt, res);
}

struct QJSABIVoidOrError qjs_object_set_property_from_value(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIValue key,
  struct QJSABIValue value
) {
  JSAtom atom = abi_value_to_atom(rt, &key);
  if (atom == JS_ATOM_NULL) {
    struct QJSABIVoidOrError res = { .void_or_error = return_void_or_error(rt, -1) };
    return res;
  }

  int ret = JS_SetProperty(rt->ctx, get_js_value(obj.pointer), atom, from_qjs_abi_value(rt, &value));
  JS_FreeAtom(rt->ctx, atom);
  struct QJSABIVoidOrError res = { .void_or_error = return_void_or_error(rt, ret) };
  return res;
}

struct QJSABIBoolOrError qjs_object_has_property_from_value(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIValue key
) {
  JSAtom atom = abi_value_to_atom(rt, &key);
  if (atom == JS_ATOM_NULL) {
    struct QJSABIBoolOrError res = { .bool_or_error = return_bool_or_error(rt, -1) };
    return res;
  }

  int ret = JS_HasProperty(rt->ctx, get_js_value(obj.pointer), atom);
  JS_FreeAtom(rt->ctx, atom);
  struct QJSABIBoolOrError res = { .bool_or_error = return_bool_or_error(rt, ret) };
  return res;
}

struct QJSABIValue qjs_object_get_property_from_propnameid(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIPropNameID name
) {
  JSValue res = JS_GetProperty(rt->ctx, get_js_value(obj.pointer), get_js_atom(name.pointer));
  if (JS_IsException(res)) return return_js_error_val(rt);
  return to_qjs_abi_value(rt, res);
}

struct QJSABIVoidOrError qjs_object_set_property_from_propnameid(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIPropNameID name,
  struct QJSABIValue value
) {
  int ret = JS_SetProperty(rt->ctx, get_js_value(obj.pointer), get_js_atom(name.pointer), from_qjs_abi_value(rt, &value));
  struct QJSABIVoidOrError res = { .void_or_error = return_void_or_error(rt, ret) };
  return res;
}

struct QJSABIBoolOrError qjs_object_has_property_from_propnameid(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIPropNameID name
) {
  int ret = JS_HasProperty(rt->ctx, get_js_value(obj.pointer), get_js_atom(name.pointer));
  struct QJSABIBoolOrError res = { .bool_or_error = return_bool_or_error(rt, ret) };
  return res;
}

struct QJSABIArrayOrError qjs_object_get_property_names(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj
) {
  JSPropertyEnum *tab;
  uint32_t len;
  int ret = JS_GetOwnPropertyNames(
    rt->ctx,
    &tab,
    &len,
    get_js_value(obj.pointer),
    JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK | JS_GPN_ENUM_ONLY
  );

  struct QJSABIArrayOrError res;
  if (ret < 0) {
    record_js_exception(rt);
    res.ptr_or_error = make_error_ptr(QJSABIErrorCodeJSError);
    return res;
  }

  JSValue arr = JS_NewArray(rt->ctx);
  for (uint32_t i = 0; i < len && !JS_IsException(arr); i++) {
    JSValue propVal = JS_AtomToValue(rt->ctx, tab[i].atom);
    if (JS_IsException(propVal) || JS_SetPropertyUint32(rt->ctx, arr, i, propVal) < 0) {
      JS_FreeValue(rt->ctx, arr);
      arr = JS_EXCEPTION;
    }
  }
  JS_FreePropertyEnum(rt->ctx, tab, len);

  res.ptr_or_error = return_ptr_or_error(rt, arr);
  return res;
}

bool qjs_object_is_function(struct QJSABIRuntime *rt, struct QJSABIObject obj) {
  return JS_IsFunction(rt->ctx, get_js_value(obj.pointer)) != 0;
}

bool qjs_object_is_array(struct QJSABIRuntime *rt, struct QJSABIObject obj) {
  (void)rt;
  return JS_IsArray(get_js_value(obj.pointer)) != 0;
}

bool qjs_object_is_arraybuffer(struct QJSABIRuntime *rt, struct QJSABIObject obj) {
  size_t size;
  return JS_GetArrayBuffer(rt->ctx, &size, get_js_value(obj.pointer)) != NULL;
}

struct QJSABIBoolOrError qjs_instance_of(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIFunction ctor
) {
  int ret = JS_IsInstanceOf(rt->ctx, get_js_value(obj.pointer), get_js_value(ctor.pointer));
  struct QJSABIBoolOrError res = { .bool_or_error = return_bool_or_error(rt, ret) };
  return res;
}

// Host objects

struct QJSABIObjectOrError qjs_object_create_from_host_object(
  struct QJSABIRuntime *rt,
  void *user_data,
  QJSABIHostObjectGet get_cb,
  QJSABIHostObjectSet set_cb,
  QJSABIHostObjectGetOwnKeys get_own_keys_cb,
  QJSABIHostObjectHas has_cb,
  QJSABIHostObjectRelease release_cb
) {
  struct QJSABIObjectOrError res;
  QJSHostObjectBridge *bridge = (QJSHostObjectBridge *)malloc(sizeof(QJSHostObjectBridge));
  if (!bridge) {
    if (release_cb) release_cb(user_data);
    res.ptr_or_error = make_error_ptr(QJSABIErrorCodeNativeException);
    return res;
  }

  JSValue obj = JS_NewObjectClass(rt->ctx, rt->host_object_class_id);
  if (JS_IsException(obj)) {
    free(bridge);
    if (release_cb) release_cb(user_data);
    res.ptr_or_error = return_ptr_or_error(rt, obj);
    return res;
  }

  bridge->user_data = user_data;
  bridge->rt = rt;
  bridge->get_cb = get_cb;
  bridge->set_cb = set_cb;
  bridge->get_own_keys_cb = get_own_keys_cb;
  bridge->has_cb = has_cb;
  bridge->release_cb = release_cb;

  JS_SetOpaque(obj, bridge);
  res.ptr_or_error = (uintptr_t)create_managed_pointer(rt, obj);
  return res;
}

// Native state
//
// The state lives in the opaque of a holder object stored under a private
// symbol, which JS code cannot see. The property is also neither writable
// nor configurable. Setting the state again swaps the holder's opaque.

// Returns the holder defined directly on obj (not inherited), JS_UNDEFINED if
// there is none, or JS_EXCEPTION.
static JSValue get_own_native_state_holder(struct QJSABIRuntime *rt, JSValueConst obj) {
  JSPropertyDescriptor desc;
  int ret = JS_GetOwnProperty(rt->ctx, &desc, obj, rt->native_state_atom);
  if (ret < 0) return JS_EXCEPTION;
  if (ret == 0) return JS_UNDEFINED;
  JS_FreeValue(rt->ctx, desc.getter);
  JS_FreeValue(rt->ctx, desc.setter);
  return desc.value;
}

struct QJSABIVoidOrError qjs_object_set_native_state(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  void *user_data,
  QJSABINativeStateRelease release_cb
) {
  QJSNativeStateBridge *b = (QJSNativeStateBridge *)malloc(sizeof(QJSNativeStateBridge));
  if (!b) {
    if (release_cb) release_cb(user_data);
    struct QJSABIVoidOrError res = { .void_or_error = make_error_ptr(QJSABIErrorCodeNativeException) };
    return res;
  }
  b->user_data = user_data;
  b->release_cb = release_cb;

  JSValueConst target = get_js_value(obj.pointer);
  JSValue holder = get_own_native_state_holder(rt, target);
  if (JS_IsException(holder)) {
    free(b);
    if (release_cb) release_cb(user_data);
    struct QJSABIVoidOrError res = { .void_or_error = return_void_or_error(rt, -1) };
    return res;
  }
  QJSNativeStateBridge *old = (QJSNativeStateBridge *)JS_GetOpaque(holder, rt->native_state_class_id);
  if (old) {
    JS_SetOpaque(holder, b);
    JS_FreeValue(rt->ctx, holder);
    if (old->release_cb) old->release_cb(old->user_data);
    free(old);
    struct QJSABIVoidOrError res = { .void_or_error = 0 };
    return res;
  }
  JS_FreeValue(rt->ctx, holder);

  JSValue ns_obj = JS_NewObjectClass(rt->ctx, rt->native_state_class_id);
  if (JS_IsException(ns_obj)) {
    free(b);
    if (release_cb) release_cb(user_data);
    struct QJSABIVoidOrError res = { .void_or_error = return_void_or_error(rt, -1) };
    return res;
  }
  // From here on b is owned by ns_obj: if the define fails, ns_obj is freed
  // and its finalizer calls release_cb.
  JS_SetOpaque(ns_obj, b);
  int ret = JS_DefinePropertyValue(rt->ctx, target, rt->native_state_atom, ns_obj, JS_PROP_THROW);

  struct QJSABIVoidOrError res = { .void_or_error = return_void_or_error(rt, ret) };
  return res;
}

void *qjs_object_get_native_state_data(struct QJSABIRuntime *rt, struct QJSABIObject obj) {
  JSValue holder = get_own_native_state_holder(rt, get_js_value(obj.pointer));
  if (JS_IsException(holder)) {
    // Only a Proxy trap can throw here; report "no state" and drop the error.
    JS_FreeValue(rt->ctx, JS_GetException(rt->ctx));
    return NULL;
  }
  QJSNativeStateBridge *b = (QJSNativeStateBridge *)JS_GetOpaque(holder, rt->native_state_class_id);
  JS_FreeValue(rt->ctx, holder);
  return b ? b->user_data : NULL;
}

// Functions

struct QJSABIValue qjs_function_call(
  struct QJSABIRuntime *rt,
  struct QJSABIFunction fn,
  struct QJSABIValue js_this,
  struct QJSABIValue *args,
  size_t arg_count
) {
  JSValue this_val = from_qjs_abi_value(rt, &js_this);
  JSValue stack_args[MAX_STACK_ARGS];
  JSValue *js_args = (arg_count <= MAX_STACK_ARGS)
    ? stack_args
    : (JSValue *)calloc(arg_count, sizeof(JSValue));
  if (!js_args) {
    JS_FreeValue(rt->ctx, this_val);
    JS_ThrowOutOfMemory(rt->ctx);
    return return_js_error_val(rt);
  }

  for (size_t i = 0; i < arg_count; i++) {
    js_args[i] = from_qjs_abi_value(rt, &args[i]);
  }

  JSValue res = JS_Call(rt->ctx, get_js_value(fn.pointer), this_val, (int)arg_count, js_args);

  JS_FreeValue(rt->ctx, this_val);
  for (size_t i = 0; i < arg_count; i++) JS_FreeValue(rt->ctx, js_args[i]);
  if (js_args != stack_args) free(js_args);

  return finish_top_level_call(rt, res);
}

struct QJSABIValue qjs_function_call_as_constructor(
  struct QJSABIRuntime *rt,
  struct QJSABIFunction fn,
  struct QJSABIValue *args,
  size_t arg_count
) {
  JSValue stack_args[MAX_STACK_ARGS];
  JSValue *js_args = (arg_count <= MAX_STACK_ARGS)
    ? stack_args
    : (JSValue *)calloc(arg_count, sizeof(JSValue));
  if (!js_args) {
    JS_ThrowOutOfMemory(rt->ctx);
    return return_js_error_val(rt);
  }

  for (size_t i = 0; i < arg_count; i++) {
    js_args[i] = from_qjs_abi_value(rt, &args[i]);
  }

  JSValue res = JS_CallConstructor(rt->ctx, get_js_value(fn.pointer), (int)arg_count, js_args);

  for (size_t i = 0; i < arg_count; i++) JS_FreeValue(rt->ctx, js_args[i]);
  if (js_args != stack_args) free(js_args);

  return finish_top_level_call(rt, res);
}

struct QJSABIFunctionOrError qjs_function_create_from_host(
  struct QJSABIRuntime *rt,
  struct QJSABIPropNameID name,
  unsigned int length,
  void *user_data,
  QJSABIHostFunctionCall call_cb,
  QJSABIHostFunctionRelease release_cb
) {
  struct QJSABIFunctionOrError res;
  QJSHostFunctionBridge *b = (QJSHostFunctionBridge *)malloc(sizeof(QJSHostFunctionBridge));
  if (!b) {
    if (release_cb) release_cb(user_data);
    res.ptr_or_error = make_error_ptr(QJSABIErrorCodeNativeException);
    return res;
  }
  b->user_data = user_data;
  b->rt = rt;
  b->call_cb = call_cb;
  b->release_cb = release_cb;

  JSValue data_obj = JS_NewObjectClass(rt->ctx, rt->host_function_class_id);
  if (JS_IsException(data_obj)) {
    free(b);
    if (release_cb) release_cb(user_data);
    res.ptr_or_error = return_ptr_or_error(rt, data_obj);
    return res;
  }
  // From here on b is owned by data_obj and released by its finalizer.
  JS_SetOpaque(data_obj, b);

  JSValue fn = JS_NewCFunctionData(rt->ctx, host_function_call, (int)length, 0, 1, &data_obj);
  JS_FreeValue(rt->ctx, data_obj);
  if (JS_IsException(fn)) {
    res.ptr_or_error = return_ptr_or_error(rt, fn);
    return res;
  }

  JSAtom name_atom = get_js_atom(name.pointer);
  if (name_atom != 0) {
    const char *name_str = JS_AtomToCString(rt->ctx, name_atom);
    if (name_str) {
      JS_DefinePropertyValueStr(rt->ctx, fn, "name", JS_NewString(rt->ctx, name_str), JS_PROP_CONFIGURABLE);
      JS_FreeCString(rt->ctx, name_str);
    }
  }

  res.ptr_or_error = return_ptr_or_error(rt, fn);
  return res;
}

// Strings

struct QJSABIStringOrError qjs_create_string_from_utf8(struct QJSABIRuntime *rt, const char *str) {
  struct QJSABIStringOrError res = { .ptr_or_error = return_ptr_or_error(rt, JS_NewString(rt->ctx, str)) };
  return res;
}

char *qjs_string_to_utf8(struct QJSABIRuntime *rt, struct QJSABIString str) {
  const char *cstr = JS_ToCString(rt->ctx, get_js_value(str.pointer));
  if (!cstr) return NULL;
  char *res = strdup(cstr);
  JS_FreeCString(rt->ctx, cstr);
  return res;
}

static struct QJSABIStringData get_utf16_string_data(struct QJSABIRuntime *rt, JSValue val) {
  if (rt->temp_string_buf) {
    JS_FreeCStringUTF16(rt->ctx, (const uint16_t *)rt->temp_string_buf);
    rt->temp_string_buf = NULL;
  }
  size_t len = 0;
  const uint16_t *ptr = JS_ToCStringLenUTF16(rt->ctx, &len, val);
  rt->temp_string_buf = (void *)ptr;

  struct QJSABIStringData res = {
    .is_ascii = false,
    .data = ptr,
    .length = len
  };
  return res;
}

struct QJSABIStringData qjs_string_get_data(struct QJSABIRuntime *rt, struct QJSABIString str) {
  return get_utf16_string_data(rt, get_js_value(str.pointer));
}

// PropNameIDs

struct QJSABIPropNameIDOrError qjs_propnameid_create_from_string(
  struct QJSABIRuntime *rt,
  struct QJSABIString str
) {
  struct QJSABIPropNameIDOrError res;
  JSAtom atom = JS_ValueToAtom(rt->ctx, get_js_value(str.pointer));
  if (atom == JS_ATOM_NULL) {
    record_js_exception(rt);
    res.ptr_or_error = make_error_ptr(QJSABIErrorCodeJSError);
    return res;
  }
  struct QJSABIManagedPointerImpl *impl = create_managed_atom(rt, atom);
  res.ptr_or_error = impl ? (uintptr_t)impl : make_error_ptr(QJSABIErrorCodeNativeException);
  return res;
}

struct QJSABIPropNameIDOrError qjs_propnameid_create_from_symbol(
  struct QJSABIRuntime *rt,
  struct QJSABISymbol sym
) {
  struct QJSABIPropNameIDOrError res;
  JSAtom atom = JS_ValueToAtom(rt->ctx, get_js_value(sym.pointer));
  if (atom == JS_ATOM_NULL) {
    record_js_exception(rt);
    res.ptr_or_error = make_error_ptr(QJSABIErrorCodeJSError);
    return res;
  }
  struct QJSABIManagedPointerImpl *impl = create_managed_atom(rt, atom);
  res.ptr_or_error = impl ? (uintptr_t)impl : make_error_ptr(QJSABIErrorCodeNativeException);
  return res;
}

char *qjs_propnameid_to_utf8(struct QJSABIRuntime *rt, struct QJSABIPropNameID name) {
  const char *str = JS_AtomToCString(rt->ctx, get_js_atom(name.pointer));
  if (!str) return NULL;
  char *res = strdup(str);
  JS_FreeCString(rt->ctx, str);
  return res;
}

struct QJSABIPropNameID qjs_propnameid_clone(struct QJSABIRuntime *rt, struct QJSABIPropNameID name) {
  struct QJSABIPropNameID res = {
    .pointer = (struct QJSABIManagedPointer *)create_managed_atom(rt, JS_DupAtom(rt->ctx, get_js_atom(name.pointer)))
  };
  return res;
}

bool qjs_propnameid_equals(
  struct QJSABIRuntime *rt,
  struct QJSABIPropNameID a,
  struct QJSABIPropNameID b
) {
  (void)rt;
  return get_js_atom(a.pointer) == get_js_atom(b.pointer);
}

struct QJSABIStringData qjs_propnameid_get_data(
  struct QJSABIRuntime *rt,
  struct QJSABIPropNameID prop
) {
  JSValue str = JS_AtomToString(rt->ctx, get_js_atom(prop.pointer));
  struct QJSABIStringData res = get_utf16_string_data(rt, str);
  JS_FreeValue(rt->ctx, str);
  return res;
}

static void prop_name_id_list_release(struct QJSABIPropNameIDList *list) {
  if (!list) return;
  for (size_t i = 0; i < list->size; i++) {
    qjs_pointer_release(list->props[i].pointer);
  }
  free((void *)list->props);
  free(list);
}

static const struct QJSABIPropNameIDListVTable g_prop_list_vtable = {
  prop_name_id_list_release
};

// Copies `props` and clones every pointer in it: the caller keeps ownership
// of both, and may free them as soon as this returns.
struct QJSABIPropNameIDList *qjs_propnameid_list_create(
  const struct QJSABIPropNameID *props,
  size_t size
) {
  struct QJSABIPropNameIDList *list =
    (struct QJSABIPropNameIDList *)malloc(sizeof(struct QJSABIPropNameIDList));
  struct QJSABIPropNameID *copy =
    (struct QJSABIPropNameID *)calloc(size > 0 ? size : 1, sizeof(struct QJSABIPropNameID));
  if (!list || !copy) {
    free(list);
    free(copy);
    return NULL;
  }
  for (size_t i = 0; i < size; i++) {
    struct QJSABIManagedPointerImpl *impl = (struct QJSABIManagedPointerImpl *)props[i].pointer;
    copy[i].pointer = impl ? qjs_managed_pointer_clone(impl->rt, props[i].pointer) : NULL;
  }
  list->vtable = &g_prop_list_vtable;
  list->size = size;
  list->props = copy;
  return list;
}

// BigInts

struct QJSABIBigIntOrError qjs_bigint_create_from_int64(struct QJSABIRuntime *rt, int64_t value) {
  struct QJSABIBigIntOrError res = {
    .ptr_or_error = return_ptr_or_error(rt, JS_NewBigInt64(rt->ctx, value))
  };
  return res;
}

bool qjs_bigint_is_int64(struct QJSABIRuntime *rt, struct QJSABIBigInt bi) {
  JSValue val = get_js_value(bi.pointer);
  int64_t v = 0;
  if (JS_ToBigInt64(rt->ctx, &v, val) != 0) return false;
  JSValue check = JS_NewBigInt64(rt->ctx, v);
  bool eq = JS_IsStrictEqual(rt->ctx, val, check);
  JS_FreeValue(rt->ctx, check);
  return eq;
}

int64_t qjs_bigint_as_int64(struct QJSABIRuntime *rt, struct QJSABIBigInt bi) {
  int64_t v = 0;
  JS_ToBigInt64(rt->ctx, &v, get_js_value(bi.pointer));
  return v;
}

// Arrays

struct QJSABIArrayOrError qjs_array_create(struct QJSABIRuntime *rt, size_t length) {
  JSValue arr = JS_NewArray(rt->ctx);
  if (length > 0 && !JS_IsException(arr) &&
      JS_SetPropertyStr(rt->ctx, arr, "length", JS_NewInt64(rt->ctx, (int64_t)length)) < 0) {
    JS_FreeValue(rt->ctx, arr);
    arr = JS_EXCEPTION;
  }
  struct QJSABIArrayOrError res = { .ptr_or_error = return_ptr_or_error(rt, arr) };
  return res;
}

size_t qjs_array_get_length(struct QJSABIRuntime *rt, struct QJSABIArray arr) {
  JSValue lenVal = JS_GetPropertyStr(rt->ctx, get_js_value(arr.pointer), "length");
  uint32_t len = 0;
  JS_ToUint32(rt->ctx, &len, lenVal);
  JS_FreeValue(rt->ctx, lenVal);
  return (size_t)len;
}

struct QJSABIValueOrError qjs_array_value_get_at_index(
  struct QJSABIRuntime *rt,
  struct QJSABIArray arr,
  size_t index
) {
  return return_val_or_error(rt, JS_GetPropertyUint32(rt->ctx, get_js_value(arr.pointer), (uint32_t)index));
}

struct QJSABIVoidOrError qjs_array_value_set_at_index(
  struct QJSABIRuntime *rt,
  struct QJSABIArray arr,
  size_t index,
  struct QJSABIValue value
) {
  int ret = JS_SetPropertyUint32(rt->ctx, get_js_value(arr.pointer), (uint32_t)index, from_qjs_abi_value(rt, &value));
  struct QJSABIVoidOrError res = { .void_or_error = return_void_or_error(rt, ret) };
  return res;
}

// ArrayBuffers

typedef struct QJSArrayBufferBridge {
  void *user_data;
  QJSABIMutableBufferRelease release_cb;
} QJSArrayBufferBridge;

static void *array_buffer_realloc_cb(JSRuntime *rt, void *opaque, void *ptr, size_t size) {
  (void)rt; (void)ptr;
  if (size == 0) {
    QJSArrayBufferBridge *b = (QJSArrayBufferBridge *)opaque;
    if (b) {
      if (b->release_cb) b->release_cb(b->user_data);
      free(b);
    }
  }
  return NULL;
}

struct QJSABIArrayBufferOrError qjs_arraybuffer_create_from_external_data(
  struct QJSABIRuntime *rt,
  uint8_t *data,
  size_t size,
  void *user_data,
  QJSABIMutableBufferRelease release_cb
) {
  QJSArrayBufferBridge *b = (QJSArrayBufferBridge *)malloc(sizeof(QJSArrayBufferBridge));
  if (!b) {
    if (release_cb) release_cb(user_data);
    struct QJSABIArrayBufferOrError res = { .ptr_or_error = make_error_ptr(QJSABIErrorCodeNativeException) };
    return res;
  }
  b->user_data = user_data;
  b->release_cb = release_cb;

  JSValue ab = JS_NewArrayBuffer(rt->ctx, data, size, size, array_buffer_realloc_cb, b, false);
  if (JS_IsException(ab)) {
    if (b->release_cb) b->release_cb(b->user_data);
    free(b);
  }
  struct QJSABIArrayBufferOrError res = { .ptr_or_error = return_ptr_or_error(rt, ab) };
  return res;
}

struct QJSABIUint8PtrOrError qjs_arraybuffer_get_data(
  struct QJSABIRuntime *rt,
  struct QJSABIArrayBuffer ab
) {
  size_t size;
  uint8_t *ptr = JS_GetArrayBuffer(rt->ctx, &size, get_js_value(ab.pointer));
  struct QJSABIUint8PtrOrError res = { .is_error = (ptr == NULL), .data.val = ptr };
  return res;
}

struct QJSABISizeTOrError qjs_arraybuffer_get_size(
  struct QJSABIRuntime *rt,
  struct QJSABIArrayBuffer ab
) {
  size_t size = 0;
  uint8_t *ptr = JS_GetArrayBuffer(rt->ctx, &size, get_js_value(ab.pointer));
  struct QJSABISizeTOrError res = { .is_error = (ptr == NULL), .data.val = size };
  return res;
}
