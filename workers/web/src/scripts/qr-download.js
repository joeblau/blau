/*
 * On a Mac, the iOS/iPadOS TestFlight links can't install anything, so clicks
 * open a dialog with a QR code (rendered at build time) to scan from the
 * device instead. iPads report a Macintosh user agent since iPadOS 13; the
 * multitouch check separates them, so real iPhones and iPads keep the direct
 * TestFlight navigation.
 */
const APPS = {
  walkie: { name: 'Walkie', device: 'iPhone' },
  kneeboard: { name: 'Kneeboard', device: 'iPad' },
};

export function initQrDownload() {
  const isMacDesktop = /Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints <= 1;
  if (!isMacDesktop) return;

  const dialog = document.querySelector('[data-qr-dialog]');
  if (!(dialog instanceof HTMLDialogElement)) return;
  const title = dialog.querySelector('[data-qr-title]');
  const codes = dialog.querySelectorAll('[data-qr-code]');

  for (const link of document.querySelectorAll('a[data-qr]')) {
    link.addEventListener('click', (event) => {
      const app = APPS[link.dataset.qr];
      if (!app) return;
      event.preventDefault();
      for (const code of codes) {
        code.toggleAttribute('hidden', code.dataset.qrCode !== link.dataset.qr);
      }
      if (title) title.textContent = `Install ${app.name} on your ${app.device}`;
      dialog.showModal();
    });
  }

  dialog.querySelector('[data-qr="close"]')?.addEventListener('click', () => dialog.close());
  dialog.addEventListener('click', (event) => {
    // The dialog element itself is only the click target on the backdrop.
    if (event.target === dialog) dialog.close();
  });
}
