/** FluxDO 脚本 API 2。服务业务在插件中实现，权限由宿主校验。 */
declare namespace FluxDO {
  type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
  type Record = { [key: string]: Json };
  type BrowserMode = 'ask' | 'inApp' | 'external' | 'preference';
  type Feature = 'browserModes' | 'automaticPagination' | 'gridLayouts' | 'virtualGrid' | 'confirmationDialog' | 'nativeExecutionLimits' | 'navigationEntries' | 'forumRead' | 'scheduledTasks' | 'localNotifications' | 'navigationBadge' | 'atomicStorage' | 'runtimePermissions' | 'adaptiveCollections' | 'modalDismiss' | 'cardNavigation' | 'contentPresentation' | 'eventStreams';
  type ManagedPermission = 'identity' | 'serviceAccount' | 'payments' | 'forumProfiles' | 'forumActivity' | 'forumFollowing' | 'background' | 'notifications' | 'links' | 'publicImages';
  type PermissionState = Partial<{[key in ManagedPermission | 'sandbox' | 'network' | 'foregroundTasks']: boolean}>;
  interface FetchOptions {
    method?: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE' | 'HEAD';
    headers?: { [key: string]: string };
    body?: Json;
    credential?: string;
    /** @deprecated 仅 API 1 */ auth?: boolean;
  }
  interface Response {
    status: number; ok: boolean; headers: { [key: string]: string }; body: string;
    json<T = Json>(): T;
  }
  interface CredentialStatus { authorized: boolean; expiresAt: number | null }
  interface Confirmation {
    title: string; message: string; confirmLabel: string;
    /** 默认不勾选，用户点击协议链接阅读，再自行勾选。 */
    agreement?: { label: string; url: string };
  }
  interface Context {
    surface: string; kind: 'card' | 'page' | 'task'; page: string | null; params: Record;
    api: Api;
    setData(key: string, value: Json): void;
  }
  type ForumResource = 'user' | 'actions' | 'reactions' | 'boosts' | 'following';
  type ForumAction = 'likes' | 'topics' | 'replies';
  type ForumRequest =
    | { resource: 'user'; username: string }
    | { resource: 'actions'; username: string; offset?: number; actions?: ForumAction[] }
    | { resource: 'reactions' | 'boosts'; username: string; before?: number }
    | { resource: 'following'; username: string; offset?: number };
  interface ForumUser { id: number; username: string; name: string | null; avatarUrl: string }
  interface ForumProfile extends ForumUser { trustLevel: number; lastSeenAt: string | null; lastPostedAt: string | null }
  interface ForumActivity {
    id: string | number; topicId: number; postNumber: number | null; title: string | null;
    excerpt: string | null; createdAt: string | null; categoryId: number | null;
    actor: ForumUser | null; author: ForumUser | null;
    action?: ForumAction; reaction?: string | null; cooked?: string; postId?: number;
  }
  type ForumResult<R extends ForumResource> = R extends 'user' ? ForumProfile :
    R extends 'following' ? {items: ForumUser[]; nextOffset: number | null} :
    R extends 'actions' ? {items: ForumActivity[]; nextOffset: number | null} :
    {items: ForumActivity[]; nextBefore: number | null};
  type ForumDestination = {type: 'topic'; topicId: number; postNumber?: number} | {type: 'user'; username: string};
  interface StreamEvent {id: string; event: string; data: string; lastEventId: string}
  interface StreamState {id: string; state: 'connecting' | 'open' | 'retrying' | 'closed'; reason?: string; status?: number; retryInMs?: number}
  interface Api {
    on<E extends string>(name: E, handler: (ctx: Context, args: E extends 'stream.event' ? StreamEvent : E extends 'stream.state' ? StreamState : Record) => void | Promise<void>): () => void;
    fetch(url: string, options?: FetchOptions): Promise<Response>;
    streams: {
      /** 连接结果和数据经 stream.state / stream.event 交付；隐藏暂停。 */
      open(options: {id: string; url: string; credential?: string; headers?: {[key: string]: string}; lastEventId?: string}): Promise<string>;
      close(id: string): Promise<null>;
    };
    host: { features(): Promise<string[]> };
    permissions: { status(): Promise<PermissionState>; request(names: ManagedPermission[]): Promise<boolean> };
    forum: {
      /** 页面可见或有有效任务租约时可读；permissions.forum 授权。 */
      read<T extends ForumRequest>(options: T): Promise<ForumResult<T['resource']>>;
      /** 用户点击后打开原生页面，无需读取权限。 */
      open(destination: ForumDestination): Promise<null>;
    };
    dialogs: { confirm(options: Confirmation): Promise<boolean> };
    storage: {
      get<T = Json>(key: string): Promise<T | null>;
      set(key: string, value: Json): Promise<null>;
      setMany(entries: Record): Promise<null>;
      compareAndSet<T>(key: string, expected: T | null, value: T | null): Promise<boolean>;
      remove(key: string): Promise<null>;
    };
    tasks: {
      schedule(options: {id: string; intervalSeconds: number; background?: boolean}): Promise<boolean>;
      list(): Promise<{id: string; intervalSeconds: number; background: boolean; nextAt: number; lastAt: number | null; error: string | null}[]>;
      cancel(id: string): Promise<null>;
    };
    notifications: {
      isAllowed(): Promise<boolean>;
      revoke(): Promise<null>;
      requestPermission(): Promise<boolean>;
      show(options: {key: string; title: string; body: string; page: string; params?: Record}): Promise<boolean>;
      cancel(key: string): Promise<null>;
    };
    navigation: {dismiss(): Promise<boolean>; setBadge(page: string, count: number): Promise<null>};
    credentials: {
      status(name: string): Promise<CredentialStatus>;
      request(name: string): Promise<boolean>;
      remove(name: string): Promise<null>;
      capture(name: string, request: FetchOptions & { url: string }, options: {
        tokenPath: (string | number)[]; expiresAtPath?: (string | number)[]; jwt?: boolean;
      }): Promise<CredentialStatus & { claims?: Record }>;
    };
    connect: { authorize(url: string): Promise<string | null> };
    payments: { request(options: {
      provider: 'linuxDoCredit'; url: string; reference: string; amount: string | number;
    }): Promise<{ state: 'paid' | 'pending' } | null> };
    crypto: {
      pkce(): Promise<{ verifier: string; challenge: string; method: 'S256' }>;
      uuid(): Promise<string>;
      sha256(text: string): Promise<string>;
    };
    /** @deprecated API 1 手填凭证；新插件使用 credentials。 */
    auth: {
      status(): Promise<{ authorized: boolean }>;
      request(): Promise<boolean>;
      signOut(): Promise<null>;
    };
    user: { get(): Promise<{ id: number; username: string } | null> };
    navigate(page: string, params?: Record): Promise<null>;
    prepareNavigation(page: string): Promise<(params?: Record) => Promise<null>>;
    session: { login(): Promise<null>; open(path: string): Promise<null> };
    openUrl(url: string): Promise<null>;
    browser: { open(url: string, options?: { mode: BrowserMode }): Promise<null> };
    toast(message: string, type?: 'info' | 'success' | 'error'): Promise<null>;
  }
}
declare const fluxdo: FluxDO.Api;
declare const console: { log(...values: unknown[]): void; info(...values: unknown[]): void; debug(...values: unknown[]): void; warn(...values: unknown[]): void; error(...values: unknown[]): void };
declare function setTimeout(callback: (...args: unknown[]) => void, delay?: number, ...args: unknown[]): number;
declare function clearTimeout(id: number): void;
