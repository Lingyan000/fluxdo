// Isolated fixture: exercise the official frame-host access and nested handshake.
(async () => {
  const results = [];
  for (const policy of ['none', 'csp', 'xfo', 'both']) {
    const frame = document.createElement('iframe');
    frame.referrerPolicy = 'no-referrer';
    const url = new URL('/probe-frame?policy=' + policy, location.origin);
    const result = {policy, parentOrigin: location.origin};
    try {
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('frame-timeout')), 3000);
        frame.onload = () => {clearTimeout(timer); resolve();};
        frame.onerror = () => {clearTimeout(timer); reject(new Error('frame-error'));};
        frame.src = url.href;
        document.body.append(frame);
      });
      const doc = frame.contentDocument;
      result.accessible = !!doc?.body;
      result.hrefMatches = frame.contentWindow.location.href === url.href;
      result.marker = doc?.querySelector('meta[name="discourse-mini-app-host"]')?.content;
      if (!result.accessible || !result.hrefMatches || result.marker !== '1') throw new Error('frame-host-invalid');
      const inner = doc.createElement('iframe');
      inner.sandbox = 'allow-scripts';
      inner.referrerPolicy = 'no-referrer';
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('handshake-timeout')), 3000);
        const listener = event => {
          if (event.source !== inner.contentWindow) return;
          if (event.data?.type === 'fixture-ready') {
            const restriction = doc.createElement('meta');
            restriction.httpEquiv = 'Content-Security-Policy';
            restriction.content = "frame-src 'none'";
            doc.head.append(restriction);
            event.ports[0].postMessage({html:'<!doctype html><html><body><script>const channel=new MessageChannel();parent.postMessage({type:"app-ready"},"*",[channel.port2]);<\/script></body></html>'});
            event.ports[0].close();
            return;
          }
          if (event.data?.type !== 'app-ready') return;
          result.sandboxOrigin = event.origin;
          result.ports = event.ports.length;
          event.ports[0].postMessage('ack');
          event.ports[0].close();
          frame.contentWindow.removeEventListener('message', listener);
          clearTimeout(timer);
          resolve();
        };
        frame.contentWindow.addEventListener('message', listener);
        inner.src = new URL('/probe-runtime', location.origin).href;
        doc.body.append(inner);
      });
      result.passed = result.sandboxOrigin === 'null' && result.ports === 1;
    } catch (error) {result.error = error.name + ': ' + error.message;}
    results.push(result);
    frame.remove();
  }
  window.sandboxProbeResults = results;
  console.log('SANDBOX_PROBE ' + JSON.stringify(results));
})();
