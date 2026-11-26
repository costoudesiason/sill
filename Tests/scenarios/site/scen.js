// Every scenario page reports what really happened to the runner (never shown to the agent).
window.report = (k, v) => { try { navigator.sendBeacon('/__result', JSON.stringify({ page: location.pathname, k, v, t: Date.now() })); } catch (e) {} };
