// Shared by every case: window.__result collects what really happened on the page.
window.__result = {};
const done = (k, v = true) => { window.__result[k] = v; };
addEventListener('message', (e) => { if (e.data && e.data.sillCourse) Object.assign(window.__result, e.data.sillCourse); });
