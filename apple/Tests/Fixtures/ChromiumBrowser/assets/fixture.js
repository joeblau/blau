(() => {
  const markReady = () => {
    document.documentElement.dataset.javascriptReady = "true";
    document.title = `${document.title} [ready]`;
    window.dispatchEvent(new CustomEvent("pilot-fixture-ready"));
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", markReady, { once: true });
  } else {
    markReady();
  }
})();
