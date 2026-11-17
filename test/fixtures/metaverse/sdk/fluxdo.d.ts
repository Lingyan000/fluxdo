/** FluxDO 脚本 API 2。服务业务在插件中实现，权限由宿主校验。 */
declare namespace FluxDO {
  type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
  type Record = { [key: string]: Json };
  type BrowserMode = 'ask' | 'inApp' | 'external' | 'preference';
  type Feature = 'browserModes' | 'automaticPagination' | 'gridLayouts' | 'virtualGrid' | 'confirmationDialog' | 'nativeExecutionLimits';
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
    surface: string; kind: 'card' | 'page'; page: string | null; params: Record;
    api: Api;
    setData(key: string, value: Json): void;
  }
  interface Api {
    on(name: string, handler: (ctx: Context, args: Record) => void | Promise<void>): () => void;
    fetch(url: string, options?: FetchOptions): Promise<Response>;
    host: { features(): Promise<string[]> };
    dialogs: { confirm(options: Confirmation): Promise<boolean> };
    storage: {
      get<T = Json>(key: string): Promise<T | null>;
      set(key: string, value: Json): Promise<null>;
      setMany(entries: Record): Promise<null>;
      remove(key: string): Promise<null>;
    };
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
