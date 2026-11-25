(function () {
  var root = document.documentElement;
  var themeBtn = document.getElementById("themeBtn");
  var themeMeta = document.querySelector('meta[name="theme-color"]');

  function applyThemeLabel() {
    var dark = root.dataset.theme === "dark";
    themeBtn.setAttribute("aria-label", dark ? "Aktifkan tema terang" : "Aktifkan tema gelap");
    themeBtn.setAttribute("aria-pressed", dark ? "true" : "false");
    if (themeMeta) themeMeta.setAttribute("content", dark ? "#171410" : "#f2ede3");
  }

  if (themeBtn && !window.ztermThemeBound) {
    applyThemeLabel();
    themeBtn.addEventListener("click", function () {
      var next = root.dataset.theme === "dark" ? "light" : "dark";
      root.dataset.theme = next;
      applyThemeLabel();
      try { localStorage.setItem("theme", next); } catch (e) {}
    });
    window.ztermThemeBound = true;
  } else if (themeMeta) {
    themeMeta.setAttribute("content", root.dataset.theme === "dark" ? "#171410" : "#f2ede3");
  }

  var toTop = document.getElementById("toTop");
  if (!toTop) return;

  var returning = false;

  function update() {
    if (returning && window.scrollY <= 600) returning = false;
    var nextHidden = returning || window.scrollY <= 600;
    if (toTop.hidden !== nextHidden) toTop.hidden = nextHidden;
  }

  window.addEventListener("scroll", update, { passive: true });
  window.addEventListener("resize", update);
  window.addEventListener("load", update);
  window.addEventListener("pageshow", update);
  update();

  toTop.addEventListener("click", function () {
    var main = document.getElementById("main");
    if (main) main.focus({ preventScroll: true });
    returning = true;
    toTop.hidden = true;
    var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    window.scrollTo({ top: 0, left: 0, behavior: reduced ? "auto" : "smooth" });
  });
})();
