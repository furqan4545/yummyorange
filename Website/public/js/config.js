/* The one place to change release details.
   - data-download links get dmgURL. While dmgURL is empty, every download button reads “Coming soon”, links nowhere,
     and the Get YummyOrange section says the first release is on its way: the page never offers a file that isn't there.
   - data-config-text="<key>" elements get the value as text; data-if-config="<key>" elements show only when it is set;
     data-unless-config="<key>" elements show only when it is not (the Open Anyway step, until the app in the DMG is notarized).
   - data-config-mailto="supportEmail" becomes a mailto: link when an address is set, and stays hidden otherwise.
   The object keeps its old internal name, window.DROPWHEEL: Tools/updates/release.sh looks for it in the live site's
   config.js to make sure UPDATE_FEED_URL points at this site. Visitors never see it. */
window.DROPWHEEL = {
  version: "1.0.0",
  dmgURL: "downloads/YummyOrange.dmg",              // the notarized DMG, e.g. "downloads/YummyOrange.dmg" or a full https:// URL
  notarized: true,        // true once the app in the DMG is notarized and stapled (hides the Open Anyway step)
  price: "",               // e.g. "Free" or "$9.99"; the Price row stays hidden while empty
  size: "7 MB",
  minimumOS: "macOS 13 Ventura or later",
  chip: "Apple silicon",   // build.sh builds for the Mac it runs on; a universal build would make this "Apple silicon or Intel"
  supportEmail: "",
};
// Set before the page paints, so the download buttons never flash a link that goes nowhere.
document.documentElement.dataset.release = window.DROPWHEEL.dmgURL ? "out" : "pending";
