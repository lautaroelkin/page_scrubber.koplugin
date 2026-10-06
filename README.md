<p align="center">
  <img src="images/page-scrubber-banner.svg" alt="Page Scrubber Banner" width="100%">
</p>

This plugin allows you to quickly flip back and forth through the book, with the option to easily return to your original page using the 'x' button or stay on the new page. You can also use the interactive progress bar and bookmark browser. Streamlined, E-ink optimized, based on KOReader's browser architecture and inspired by the native Kindle page picker experience. Compatible with EPUB, CBZ, and PDFs and works seamlessly in both portrait and landscape modes! 
   
### Features
*   **Thumbnail Grids:** Live 3-page and Multi-page previews, plus a minimalist distraction-free "Simple Grid" mode.
*   **Interactive Index:** A dedicated visual Table of Contents view with its own progress bar for easy chapter navigation.
*   **Advanced Navigation:** Interactive progress slider, chapter-skip buttons, a quick-access top toolbar, and physical D-Pad support.
*   **Split-View Annotations:** A beautiful split-screen manager for Bookmarks, Highlights, and Notes, featuring a live high-res page preview and smart highlight filters.
*   **Redesigned Reading Pop-Ups :** Features a modern, pill-shaped floating dictionary and multi-word selection menu. It intelligently anchors away from your finger so it never blocks your text. Fully compatible with the AI Assistant, X-Ray, and other external plugins.
*   **Robust Customization :** Auto-adapting layout with dynamic UI Scaling and customizable Text Size (Small/Medium/Large), choose your own optional custom wallpaper and even pick a font to change the system font of Koreader.
* **Quick Menu:** A quick-access overlay featuring two dedicated tabs for seamless reading management:
  * **Quick Actions:** Instantly access device controls (toggle front light, day/night mode), execute custom shortcuts (scrubber actions), and navigate settings.
  * **Typography (Aa):** Personalize your reading experience on the fly by selecting your favorite fonts, adjusting text size, and modifying line spacing.
*   **Markdown Export:** Export your highlights and notes directly to a `.md` file on your device.
*   **Native Integration:** Launch all widgets and access settings directly from KOReader's native top menu, or bind them to your own custom gestures.

---

### How different is this from the stock Skim widget and Page browser?

While it achieves similar goals as the stock tools, it merges the Page Browser and Skim Widget into a single, fluid, and highly interactive workflow.

Here is what it does differently:
*   **Smarter Rendering:** The 3-grid renders images one by one instead of processing all pages at once, making it significantly smoother.
*   **Hold to Flip:** Introduces a "hold" action to quickly scrub through pages.
*   **Classic "Simple Grid":** A transparent, older-Kindle inspired grid. Tap outside the window to instantly cancel and return to your original page.
*   **Instant Switching:** Jump seamlessly between the 3-page and Multi-page grids with a single tap, no menus required.
*   **Integrated TOC & Annotations:** View chapters, bookmarks, highlights, and notes on the fly while simultaneously looking at the live page preview.

Basically, it takes the native features, removes the friction, and puts them into a streamlined tool. Give it a try!

> ⚠️¡! **Compatibility Note:** Page Scrubber is *not* compatible with the `2-reader-header.lua` user patch (it will cause blank thumbnails). If you want a reading header, please use the official **Bookend** plugin instead, which is 100% compatible.

---

<table align="center" width="100%">
  <tr>
    <td align="center" width="25%" valign="top">
      <img src="images/Grid.jpg" width="100%" alt="Grid"/><br>
      <b>Grid</b>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="images/Simple-Grid.jpg" width="100%" alt="Simple Grid"/><br>
      <b>Simple Grid</b>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="images/Multi-Grid.jpg" width="100%" alt="Multi Grid"/><br>
      <b>Multi Grid</b>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="images/Index.jpg" width="100%" alt="Index"/><br>
      <b>Index</b>
    </td>
  </tr>
  <tr>
    <td align="center" width="25%" valign="top">
      <img src="images/Split-View.jpg" width="100%" alt="Split View"/><br>
      <b>Split View</b>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="images/Quick-menu.jpg" width="100%" alt="Quick menu"/><br>
      <b>Quick menu</b>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="images/PopUp-SelectionMenu.jpg" width="100%" alt="PopUp SelectionMenu"/><br>
      <b>PopUp Selection Menu</b>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="images/PopUp-Dictionary.jpg" width="100%" alt="PopUp Dictionary"/><br>
      <b>PopUp Dictionary</b>
    </td>
  </tr>
</table>

---

## ⚙️ Installation:
Download `page_scrubber.koplugin-vX.Y.Z.zip` from the [latest release](../../releases/latest) (under **Assets**, not "Source code"), unzip it, copy the `page_scrubber.koplugin` folder into `koreader/plugins/` and restart KOReader.

---

## Tutorial if needed: **How to Open Page Scrubber**
*  **Option 1 (Menu):** Open a book in KOReader, go to the document menu tab (where native Table of Contents, Bookmarks, etc. live — often on the second page), and tap **Page Scrubber** to access all grids, widgets, and settings.
*  **Option 2 (Recommended - Gestures):** Assign a gesture for instant access. Go to KOReader settings > gear tab > **Taps and gestures** > **Gesture manager** > choose a gesture (e.g., *one finger swipe: right edge up*) > **Reader** > scroll and select it to any of the available actions: **Page Scrubbers: Grid**, **Page Scrubbers: Simple grid**, **Page Scrubbers: Multi-grid**, **Page Scrubbers: Menu (BM)**, **Page Scrubbers: Menu (highlights)**, or **Page Scrubbers: Index**. And now you can also open the quick menu with a gesture: look for **Page Scrubber: Quick Menu**

---

## Useful Gestures & Shortcuts

>* **Pinch / Spread (Grid):** Pinch or spread in the grid view to toggle between the 3x2 Multi-grid and the standard grid.
>* **Long press Multi-grid button:** Switches to Simple Grid.
>* **Long press TOC button:** Opens the full index with the bottom bar hidden.
>* **Notes button / Long press bottom bookmark icon:** Opens the split menu.
>* **Long press Notes button:** Opens the split menu directly on the highlights tab.
>* **Settings button:** Opens the mini menu (open Scrubber Action with the wharehouse icon).
>* **Long press Settings button:** Opens Scrubber Actions (configurable in settings).
>* **Long press any page thumbnail:** Opens the split menu focused on that specific page.
>* **Tap top-right corner:** Toggle bookmark.
>* **Swipe down:** To Exit (X).

---

## _RTL Support_
Page Scrubber fully supports Right-to-Left reading order for manga, comics, and right-to-left documents:

* **Automatic Detection:** Automatically adapts to RTL if detected in document metadata such as CBZ or CBR files or KOReader native reading order settings.
* **Manual Override:** Easily force RTL mode for any specific book by going to Settings > Layout > RTL.
* **Gestures & Quick Actions:** Toggle RTL on the fly via KOReader native Gesture Manager under Reader > Page Scrubber: Toggle RTL or by adding it directly to your Scrubber Actions launcher.
* **Per-Document Isolation:** Manual overrides are saved exclusively to the active book local settings in doc_settings, leaving the rest of your library untouched.

## _Stable Pages (Pagemap) Support_
Works automatically out of the box with zero setup:

* **1:1 Print Parity:** Matches physical book numbering with zero drift.
* **Accurate Totals & Breaks:** Instantly detects mid-screen page breaks and displays genuine physical book totals across sliders and chapters.
