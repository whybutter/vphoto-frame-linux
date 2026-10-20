// FRAME_DEBUG_TOUCH=1: logs what the page receives for each touch -- start/end
// points, how far the finger moved, whether a click followed, and the element
// it landed on -- to /var/log/frame-shell.log. For "some buttons don't react".
(function () {
  "use strict";
  var log = function (m) {
    try { window.webkit.messageHandlers.frameShell.postMessage(JSON.stringify({ m: "log", a: m })); } catch (e) {}
  };
  var name = function (el) {
    if (!el || !el.tagName) return "?";
    var s = el.tagName.toLowerCase();
    if (el.id) s += "#" + el.id;
    if (el.className && typeof el.className === "string") s += "." + el.className.trim().split(/\s+/).slice(0, 2).join(".");
    var t = (el.textContent || "").trim().replace(/\s+/g, " ").slice(0, 24);
    return t ? s + " '" + t + "'" : s;
  };
  var start = null, moves = 0;
  addEventListener("touchstart", function (e) {
    var t = e.changedTouches[0];
    start = { x: t.clientX, y: t.clientY, at: Date.now() }; moves = 0;
    log("touchstart " + Math.round(t.clientX) + "," + Math.round(t.clientY) + " n=" + e.touches.length + " on " + name(e.target));
  }, { capture: true, passive: true });
  addEventListener("touchmove", function () { moves++; }, { capture: true, passive: true });
  addEventListener("touchend", function (e) {
    var t = e.changedTouches[0];
    var d = start ? Math.round(Math.hypot(t.clientX - start.x, t.clientY - start.y)) : -1;
    log("touchend moved " + d + "px in " + moves + " moves, " + (start ? Date.now() - start.at : -1) + "ms");
  }, { capture: true, passive: true });
  addEventListener("touchcancel", function () { log("touchcancel"); }, { capture: true, passive: true });
  ["pointerdown", "pointerup", "pointercancel", "click"].forEach(function (k) {
    addEventListener(k, function (e) {
      log(k + " " + (e.pointerType || "") + " " + Math.round(e.clientX) + "," + Math.round(e.clientY) + " on " + name(e.target));
    }, { capture: true, passive: true });
  });
})();
