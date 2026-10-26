/// 拷贝漫画 0.1.0 将 URLSearchParams 转成字符串，却未声明表单类型。
/// 仅为该插件的收藏接口补齐请求头，不改通用 fetch 的字符串行为。
const copyComicPluginId = 'b28da416-f2d4-4208-a85e-8b4c7c648e48';

String applyPluginBundleCompatibility(String pluginId, String bundle) {
  if (pluginId.trim() != copyComicPluginId) return bundle;
  return '$_copyFavoriteHttpCompatibility\n$bundle';
}

const _copyFavoriteHttpCompatibility = r'''
;(() => {
  if (globalThis.__breezeCopyFavoriteHttpFixed) return;
  const originalFetch = globalThis.fetch.bind(globalThis);
  globalThis.fetch = async function(input, init) {
    const url = input instanceof Request ? input.url : String(input);
    const method = String((init && init.method) ||
      (input instanceof Request ? input.method : "GET")).toUpperCase();
    if (method !== "POST" || !/\/member\/collect\/comic(?:[?#]|$)/.test(url)) {
      return originalFetch(input, init);
    }
    const request = new Request(input, init);
    const contentType = request.headers.get("content-type") || "";
    if (!contentType || /^text\/plain(?:;|$)/i.test(contentType)) {
      const form = new URLSearchParams(await request.clone().text());
      if (form.get("comic_id") && form.get("is_collect") === "1") {
        const headers = new Headers(request.headers);
        headers.set("content-type", "application/x-www-form-urlencoded;charset=UTF-8");
        return originalFetch(new Request(request, { headers }));
      }
    }
    return originalFetch(input, init);
  };
  globalThis.__breezeCopyFavoriteHttpFixed = true;
})();
''';
