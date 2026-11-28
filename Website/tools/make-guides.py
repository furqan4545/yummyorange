#!/usr/bin/env python3
"""Writes the website's task pages ("guides"), the guides hub, sitemap.xml, robots.txt and llms.txt into public/.

Each guide answers one job people search for (edit a PDF, HEIC to JPG, save an Instagram video...) the way YummyOrange
does it, with steps, what else it can do and a short FAQ, plus JSON-LD (breadcrumbs, FAQ) that search engines and AI
assistants read. Every claim comes from the app's README; change both together. Run after editing:

    python3 Website/tools/make-guides.py
"""
import html
import json
import pathlib
import re

SITE = "https://yummyorange.com"
PUBLIC = pathlib.Path(__file__).resolve().parent.parent / "public"
TODAY = "2026-11-28"

FACTS = "Free and open source (MIT) · macOS 13 Ventura or later · Apple silicon · about 7 MB"
APP_ID = f"{SITE}/#app"

LINK_NOTES = [
    "The first time, YummyOrange asks before downloading <a href=\"https://github.com/yt-dlp/yt-dlp\">yt-dlp</a>, the free, open-source downloader it uses (about 37 MB), from yt-dlp’s own GitHub page, and keeps it only if it matches yt-dlp’s published checksum.",
    "For a post that only signed-in visitors can see, YummyOrange asks, every time, before using your sign-in from the browser you dragged the link from (Chrome, Edge, Firefox, Brave, Vivaldi or Opera).",
    "Nothing goes through a website or server of ours: the video comes straight from the site to your Mac.",
    "Please download only your own posts, or posts whose owner allows it.",
]

GUIDES = [
    {
        "slug": "edit-pdf-on-mac", "group": "PDF",
        "title": "Edit PDF text on a Mac for free – YummyOrange",
        "desc": "Change a line of text in a PDF on your Mac, in the PDF’s own font, or add new text. Free and open source, nothing is uploaded, and the original PDF is never changed.",
        "h1": "Edit PDF text on a Mac",
        "short": "Change a line of a PDF’s text in its own font, or add text.",
        "lede": "YummyOrange’s <strong>Edit PDF</strong> changes a line of a PDF’s text in place, in the PDF’s own font, and adds new text. It is free, runs on your Mac with nothing uploaded, and saves the result as a new file, “name edited.pdf”, next to the original, which it never changes.",
        "how": "edit a PDF",
        "steps": [
            "Open YummyOrange. It lives in the menu bar.",
            "Start dragging the PDF from Finder or the desktop, and press <strong>⌘ Command</strong>. The Tools wheel opens under the pointer.",
            "Let go on <strong>Edit PDF…</strong>. A window opens with the page.",
            "Click a line and change its words, or add text where you need it.",
            "Save. “name edited.pdf” appears beside the original. It is saved as an incremental update, so the rest of the file stays exactly as it was.",
        ],
        "more_title": "More you can do with a PDF",
        "more": [
            "<strong>Organize…</strong> pages: reorder, rotate, duplicate, delete and insert.",
            "<strong>Merge</strong> two or more PDFs into one, or <strong>Split Pages</strong> into one PDF per page.",
            "<strong>Compress</strong>, or <strong>Compress to…</strong> a size in MB for an email limit.",
            "<strong>Add Password</strong> or <strong>Remove Password</strong>, make a <strong>PDF/A</strong> copy, <strong>Strip Metadata</strong>, <strong>Extract Text</strong>.",
            "Convert it with <strong>⇧ Shift</strong>: to Word (DOCX), TXT, Markdown, EPUB, PPTX, XLSX, PNG, JPG or SVG.",
        ],
        "faq": [
            ("Is it really free?", "Yes. YummyOrange is free and open source under the MIT licence. There’s no account, no watermark and no trial."),
            ("Is my PDF uploaded anywhere?", "No. Editing happens on your Mac and the PDF never leaves it."),
            ("Can I edit a scanned PDF?", "Edit PDF changes the text a PDF really contains. For a scan, Extract Text and the TXT and Markdown conversions read the page with text recognition (OCR)."),
            ("Which Macs does it run on?", "Macs with Apple silicon and macOS 13 Ventura or later."),
        ],
        "related": ["pdf-to-word-on-mac", "compress-files-on-mac", "convert-files-on-mac"],
    },
    {
        "slug": "pdf-to-word-on-mac", "group": "PDF",
        "title": "Convert PDF to Word (DOCX) on Mac for free – YummyOrange",
        "desc": "Turn a PDF into an editable Word document on your Mac: drag it, press Shift, let go on DOCX. Also TXT, Markdown, EPUB, PPTX, XLSX and images. Free, nothing uploaded.",
        "h1": "Convert a PDF to Word on a Mac",
        "short": "PDF to an editable DOCX, and to TXT, Markdown, EPUB, PPTX, XLSX or images.",
        "lede": "Drag the PDF, press <strong>⇧ Shift</strong> and let go on <strong>DOCX</strong>: YummyOrange saves an editable Word document next to the PDF. It’s free and open source, works on your Mac with nothing uploaded, and never changes the original.",
        "how": "convert a PDF to Word",
        "steps": [
            "Open YummyOrange from the menu bar.",
            "Start dragging the PDF and press <strong>⇧ Shift</strong>. The Convert wheel opens with the formats a PDF can become.",
            "Let go on <strong>DOCX</strong>.",
            "“name.docx” is saved beside the PDF, ready to open in Word or Pages.",
        ],
        "more_title": "Everything a PDF can become",
        "more": [
            "<strong>DOCX</strong> (Word), <strong>EPUB</strong>, <strong>PPTX</strong> and <strong>XLSX</strong>.",
            "<strong>TXT</strong> and <strong>Markdown</strong>: the text reflowed, with text recognition (OCR) for scanned pages.",
            "<strong>PNG</strong>, <strong>JPG</strong> and <strong>SVG</strong> images of its pages.",
            "Several PDFs at once: select them all and drag them together.",
            "The other way round too: Word (DOCX, DOC), RTF, HTML, TXT, Markdown, ODT and Pages documents convert to PDF.",
        ],
        "faq": [
            ("Is the Word file editable?", "Yes. The text comes across as editable text. A very complex layout may need tidying in Word or Pages."),
            ("Does it upload my PDF?", "No. The conversion runs on your Mac; nothing is sent anywhere."),
            ("Is it free?", "Yes. YummyOrange is free and open source under the MIT licence."),
        ],
        "related": ["edit-pdf-on-mac", "convert-files-on-mac", "compress-files-on-mac"],
    },
    {
        "slug": "convert-files-on-mac", "group": "Converting",
        "title": "Free file converter for Mac: images, video, audio, PDF, documents – YummyOrange",
        "desc": "Convert images, video, audio, PDFs, documents, ebooks, slides, spreadsheets and subtitles on your Mac. Drag a file, press Shift, drop it on a format. Free, open source, offline.",
        "h1": "Convert any file on your Mac",
        "short": "Every format YummyOrange converts between, in one place.",
        "lede": "YummyOrange converts images, video, audio, PDFs, documents, ebooks, slides, spreadsheets and subtitles on your Mac. Drag a file, press <strong>⇧ Shift</strong> and drop it on the format you want; the new file is saved next to the original, which is never changed. It’s free and open source, and nothing is uploaded.",
        "how": "convert a file",
        "steps": [
            "Open YummyOrange from the menu bar.",
            "Start dragging one file, or several, and press <strong>⇧ Shift</strong>. The Convert wheel shows the formats your files can become.",
            "Let go on a format. The new files are saved next to the originals as “name.ext” (or “name 2.ext” if that name is taken).",
        ],
        "table": [
            ("Images", "JPG, PNG, HEIC, WebP, TIFF, AVIF, GIF, BMP, PDF, PPTX"),
            ("Video", "MP4, MOV, MKV, WebM, AVI, WMV, GIF, MP3, M4A, WMA"),
            ("Audio", "MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA"),
            ("PDF", "PNG, JPG, SVG, DOCX, TXT, Markdown, EPUB, PPTX, XLSX"),
            ("Documents (DOCX, DOC, RTF, HTML, TXT, Markdown, ODT)", "PDF, each other, EPUB"),
            ("EPUB and Pages", "PDF, DOCX, TXT, Markdown, HTML, RTF, EPUB"),
            ("PowerPoint (PPTX, PPT)", "PDF, PNG, JPG, PPTX"),
            ("Spreadsheets (XLSX, XLS, ODS, CSV, TSV)", "Each other, PDF"),
            ("Subtitles", "SRT ↔ VTT, TXT"),
            ("Folders and mixed selections", "ZIP, TAR, GZIP"),
            ("Links from YouTube, X, Instagram, TikTok, Threads", "MP4, MP3, M4A, WAV"),
        ],
        "faq": [
            ("Can I convert many files at once?", "Yes. Select them and drag them together. For a mix of kinds, the wheel offers the formats every file can reach."),
            ("Do I need to install anything else?", "No. Audio and video use ffmpeg; if your Mac doesn’t have it, YummyOrange downloads its own copy from yummyorange.com once (about 12 MB). Saving pictures as WebP works the same way."),
            ("Does it work offline?", "Yes, everything except downloads from links runs on your Mac with no internet."),
        ],
        "related": ["heic-to-jpg-on-mac", "mov-to-mp4-on-mac", "pdf-to-word-on-mac", "video-to-mp3-on-mac"],
    },
    {
        "slug": "heic-to-jpg-on-mac", "group": "Converting",
        "title": "Convert HEIC to JPG on Mac for free – YummyOrange",
        "desc": "Turn iPhone HEIC photos into JPG on your Mac: drag one or many, press Shift, let go on JPG. Also PNG, WebP, TIFF, AVIF and PDF. Free, open source, nothing uploaded.",
        "h1": "Convert HEIC photos to JPG on a Mac",
        "short": "iPhone photos to JPG, PNG, WebP or PDF, many at once.",
        "lede": "iPhone photos arrive as HEIC. Drag one or many, press <strong>⇧ Shift</strong> and let go on <strong>JPG</strong>: YummyOrange saves JPG copies next to the originals, on your Mac, for free.",
        "how": "convert HEIC to JPG",
        "steps": [
            "Open YummyOrange from the menu bar.",
            "Select the HEIC photos in Finder and start dragging them. Press <strong>⇧ Shift</strong>.",
            "Let go on <strong>JPG</strong>. A JPG copy of each photo is saved beside it; the HEIC files stay as they were.",
        ],
        "more_title": "More you can do with photos",
        "more": [
            "Convert to <strong>PNG</strong>, <strong>WebP</strong>, <strong>TIFF</strong>, <strong>AVIF</strong>, <strong>GIF</strong>, <strong>BMP</strong> or <strong>PDF</strong>, or <strong>PPTX</strong> with one slide each.",
            "With <strong>⌘ Command</strong>: <strong>Compress</strong> or <strong>Compress to…</strong> a size in MB, <strong>Resize…</strong>, <strong>Half Size</strong>, <strong>Crop…</strong>, <strong>Rotate 90°</strong>.",
            "<strong>Strip Metadata</strong> saves a copy without camera and location details.",
            "<strong>Make PDF</strong> or <strong>Collage</strong> from several photos; <strong>Add Background…</strong> puts a photo on a wallpaper, gradient or colour.",
        ],
        "faq": [
            ("Can I convert a whole batch?", "Yes. Select all the photos and drag them together; each gets its own JPG."),
            ("Are the originals kept?", "Yes. YummyOrange never changes the file you drop; the JPG is a new file next to it."),
            ("Is it free?", "Yes, free and open source under the MIT licence."),
        ],
        "related": ["convert-files-on-mac", "compress-files-on-mac", "pdf-to-word-on-mac"],
    },
    {
        "slug": "mov-to-mp4-on-mac", "group": "Video and audio",
        "title": "Convert MOV to MP4 on Mac for free – YummyOrange",
        "desc": "Convert MOV screen recordings and iPhone videos to MP4 on your Mac: drag, press Shift, let go on MP4. Also MKV, WebM, AVI, GIF and MP3. Free and open source.",
        "h1": "Convert MOV to MP4 on a Mac",
        "short": "Screen recordings and iPhone videos to MP4, GIF or MP3.",
        "lede": "Drag a MOV (a screen recording, an iPhone video), press <strong>⇧ Shift</strong> and let go on <strong>MP4</strong>: YummyOrange saves an MP4 next to it, on your Mac. Free and open source, with nothing uploaded.",
        "how": "convert MOV to MP4",
        "steps": [
            "Open YummyOrange from the menu bar.",
            "Start dragging the video and press <strong>⇧ Shift</strong>.",
            "Let go on <strong>MP4</strong>. “name.mp4” is saved beside the original.",
        ],
        "more_title": "More you can do with a video",
        "more": [
            "Convert to <strong>MKV</strong>, <strong>WebM</strong>, <strong>AVI</strong>, <strong>WMV</strong>, <strong>GIF</strong>, or just its sound as <strong>MP3</strong>, <strong>M4A</strong> or <strong>WMA</strong>.",
            "With <strong>⌘ Command</strong>: <strong>Compress</strong> or <strong>Compress to…</strong> a size, <strong>Trim…</strong>, <strong>Split…</strong>, <strong>Crop…</strong>, <strong>Speed…</strong>, <strong>Mute</strong>, <strong>Extract Audio</strong>, <strong>Snapshot…</strong> of a frame.",
            "<strong>Merge</strong> two or more videos into one file.",
        ],
        "faq": [
            ("Do I need ffmpeg?", "YummyOrange uses ffmpeg for video. If your Mac doesn’t have it, YummyOrange downloads its own copy from yummyorange.com once (about 12 MB) and uses that."),
            ("Is the original changed?", "No. The MP4 is a new file next to the MOV."),
            ("Is it free?", "Yes, free and open source under the MIT licence."),
        ],
        "related": ["trim-video-on-mac", "video-to-mp3-on-mac", "compress-files-on-mac"],
    },
    {
        "slug": "compress-files-on-mac", "group": "Video and audio",
        "title": "Compress PDFs, photos and videos on Mac for free – YummyOrange",
        "desc": "Make PDFs, images, videos and audio smaller on your Mac, or shrink them to a size in MB for an email limit. Drag, press Command, drop on Compress. Free and open source.",
        "h1": "Compress files on a Mac",
        "short": "Smaller PDFs, photos, videos and sounds, or a target size in MB.",
        "lede": "Drag a file, press <strong>⌘ Command</strong> and let go on <strong>Compress</strong>, or on <strong>Compress to…</strong> to hit a size in MB, such as an email attachment limit. YummyOrange saves the smaller copy next to the original, on your Mac, for free.",
        "how": "compress a file",
        "steps": [
            "Open YummyOrange from the menu bar.",
            "Start dragging a PDF, image, video or sound file and press <strong>⌘ Command</strong>. The Tools wheel opens.",
            "Let go on <strong>Compress</strong>, or on <strong>Compress to…</strong> and type the size you need.",
            "The smaller copy is saved beside the original, which stays as it was.",
        ],
        "more_title": "What can be compressed",
        "more": [
            "<strong>PDFs</strong>: Compress and Compress to….",
            "<strong>Images</strong>: Compress, Compress to…, Half Size and Resize….",
            "<strong>Video and audio</strong>: Compress and Compress to….",
            "<strong>Folders</strong> and groups of files: ZIP, TAR or GZIP from the ⇧ Shift wheel, or Zip from the ⌥ Option wheel.",
        ],
        "faq": [
            ("Can it make a file fit an email limit?", "Yes. Compress to… asks for a size in MB and makes the copy fit it."),
            ("Is anything uploaded?", "No. Compression happens on your Mac."),
            ("Is it free?", "Yes, free and open source under the MIT licence."),
        ],
        "related": ["edit-pdf-on-mac", "mov-to-mp4-on-mac", "heic-to-jpg-on-mac"],
    },
    {
        "slug": "trim-video-on-mac", "group": "Video and audio",
        "title": "Trim and cut video on Mac, frame-accurate and free – YummyOrange",
        "desc": "Trim a video or sound on your Mac with a film strip and in and out handles, frame-accurate, in the file’s own format. Split, merge, crop and speed up too. Free and open source.",
        "h1": "Trim a video on a Mac",
        "short": "Frame-accurate cuts in the file’s own format; split and merge too.",
        "lede": "Drag a video, press <strong>⌘ Command</strong> and let go on <strong>Trim…</strong>: a window with a film strip and in and out handles makes exact, frame-accurate cuts, saved in the file’s own format next to the original. Free and open source, on your Mac.",
        "how": "trim a video",
        "steps": [
            "Open YummyOrange from the menu bar.",
            "Start dragging the video (or a sound file) and press <strong>⌘ Command</strong>.",
            "Let go on <strong>Trim…</strong>. Move the in and out handles on the film strip (a waveform for sound).",
            "Save. The trimmed copy is saved beside the original.",
        ],
        "more_title": "More video editing",
        "more": [
            "<strong>Split…</strong>: put splits on a timeline, like a video editor, or split evenly, and save each part.",
            "<strong>Merge</strong> two or more videos or sounds into one file, in the order you dropped them.",
            "<strong>Crop…</strong>, <strong>Speed…</strong> (0.25× to 4×, pitch kept), <strong>Mute</strong>, <strong>Redact…</strong> (blur or black boxes for a time range), <strong>Snapshot…</strong> of an exact frame.",
        ],
        "faq": [
            ("Is the cut exact?", "Yes, Trim makes frame-accurate cuts in the file’s own format."),
            ("Does it work for audio?", "Yes. Sound files open with a waveform instead of a film strip."),
            ("Is it free?", "Yes, free and open source under the MIT licence."),
        ],
        "related": ["mov-to-mp4-on-mac", "video-to-mp3-on-mac", "compress-files-on-mac"],
    },
    {
        "slug": "video-to-mp3-on-mac", "group": "Video and audio",
        "title": "Convert video to MP3 on Mac (extract audio) for free – YummyOrange",
        "desc": "Take the sound out of a video on your Mac as MP3, M4A or WAV: drag the video, press Shift, let go on MP3. Works for links from YouTube, Instagram and TikTok too. Free.",
        "h1": "Convert a video to MP3 on a Mac",
        "short": "The sound of any video, or of a post you have a link to.",
        "lede": "Drag a video, press <strong>⇧ Shift</strong> and let go on <strong>MP3</strong>: YummyOrange saves the sound as an MP3 next to the video. With <strong>⌘ Command</strong>, <strong>Extract Audio</strong> copies the sound out without re-encoding when it can. Free and open source, on your Mac.",
        "how": "convert a video to MP3",
        "steps": [
            "Open YummyOrange from the menu bar.",
            "Start dragging the video and press <strong>⇧ Shift</strong>.",
            "Let go on <strong>MP3</strong> (or <strong>M4A</strong>, <strong>WMA</strong>). The sound is saved beside the video.",
        ],
        "more_title": "More ways to get the sound",
        "more": [
            "From a link: drag a YouTube, X, Instagram, TikTok or Threads address out of the browser, press ⇧ Shift, let go on <strong>MP3</strong>, <strong>M4A</strong> or <strong>WAV</strong>.",
            "<strong>Normalize</strong> evens out the loudness; <strong>Channels…</strong> makes it mono or stereo, or swaps sides.",
            "Convert sound files between MP3, M4A, WAV, FLAC, OGG, Opus, AIFF and WMA.",
        ],
        "faq": [
            ("Which is better, MP3 or Extract Audio?", "Extract Audio copies AAC sound (most MP4 and MOV videos) into an M4A without re-encoding, so nothing is lost, and saves any other sound as MP3. The MP3 petal always makes an MP3, for players that need one."),
            ("Is it free?", "Yes, free and open source under the MIT licence."),
        ],
        "related": ["download-videos-from-links-on-mac", "mov-to-mp4-on-mac", "trim-video-on-mac"],
    },
    {
        "slug": "download-instagram-videos-on-mac", "group": "Saving videos from links",
        "title": "Download Instagram Reels and videos on Mac (MP4 or MP3) – YummyOrange",
        "desc": "Save an Instagram Reel or video on your Mac: drag its address out of the browser, press Shift, let go on MP4 or MP3. Free and open source; it goes straight to Downloads.",
        "h1": "Save Instagram videos on a Mac",
        "short": "Reels and video posts as MP4, or just their sound as MP3.",
        "lede": "Drag an Instagram post’s address out of your browser, press <strong>⇧ Shift</strong> and let go on <strong>MP4</strong> for the video or <strong>MP3</strong> for its sound. YummyOrange saves the file in Downloads, named after the post. Free and open source, on your Mac.",
        "how": "save an Instagram video",
        "steps": [
            "Open the Reel or post in Safari, Chrome, Edge, Firefox or another browser.",
            "Press on the address in the address bar and drag it out. A link or thumbnail on a page works too.",
            "Press <strong>⇧ Shift</strong>. The Convert wheel opens with <strong>MP4</strong>, <strong>MP3</strong>, <strong>M4A</strong> and <strong>WAV</strong>.",
            "Let go on MP4 for the video, or MP3 for the sound. It downloads into Downloads.",
        ],
        "more_title": "Good to know",
        "more": LINK_NOTES,
        "faq": [
            ("Does it work with Reels?", "Yes: Reels, video posts and IGTV links (instagram.com/reel/…, /p/…, /tv/…)."),
            ("Can I get just the audio?", "Yes. Let go on MP3, M4A or WAV instead of MP4."),
            ("Do I need an Instagram account?", "Not for public posts. For posts only signed-in visitors see, YummyOrange can use your browser’s sign-in, and asks first."),
            ("Is it free?", "Yes, free and open source under the MIT licence."),
        ],
        "related": ["download-tiktok-videos-on-mac", "download-videos-from-links-on-mac", "video-to-mp3-on-mac"],
    },
    {
        "slug": "download-tiktok-videos-on-mac", "group": "Saving videos from links",
        "title": "Download TikTok videos on Mac (MP4 or MP3) – YummyOrange",
        "desc": "Save a TikTok video on your Mac: drag its address out of the browser, press Shift, let go on MP4 or MP3. Short vm.tiktok.com links work too. Free and open source.",
        "h1": "Save TikTok videos on a Mac",
        "short": "TikTok videos as MP4, or their sound as MP3.",
        "lede": "Drag a TikTok video’s address out of your browser, press <strong>⇧ Shift</strong> and let go on <strong>MP4</strong> or <strong>MP3</strong>. YummyOrange saves it in Downloads, named after the video. Free and open source, on your Mac.",
        "how": "save a TikTok video",
        "steps": [
            "Open the video on tiktok.com in your browser.",
            "Press on the address in the address bar and drag it out (a shared vm.tiktok.com or vt.tiktok.com link works too).",
            "Press <strong>⇧ Shift</strong> and let go on <strong>MP4</strong> for the video or <strong>MP3</strong> for the sound.",
            "The file appears in Downloads.",
        ],
        "more_title": "Good to know",
        "more": LINK_NOTES,
        "faq": [
            ("Do short share links work?", "Yes: tiktok.com/@name/video/…, tiktok.com/t/…, vm.tiktok.com and vt.tiktok.com links."),
            ("Can I save only the sound?", "Yes. Let go on MP3, M4A or WAV."),
            ("Is it free?", "Yes, free and open source under the MIT licence."),
        ],
        "related": ["download-instagram-videos-on-mac", "download-videos-from-links-on-mac", "video-to-mp3-on-mac"],
    },
    {
        "slug": "download-videos-from-links-on-mac", "group": "Saving videos from links",
        "title": "Download YouTube, X and Threads videos on Mac (MP4 or MP3) – YummyOrange",
        "desc": "Save a video from YouTube, X (Twitter) or Threads on your Mac: drag its address out of the browser, press Shift, let go on MP4 or MP3. Free and open source.",
        "h1": "Save videos from YouTube, X and Threads on a Mac",
        "short": "Any supported link as MP4, MP3, M4A or WAV.",
        "lede": "YummyOrange saves videos, or just their sound, from links to YouTube, X (Twitter), Instagram, TikTok and Threads. Drag the address out of your browser, press <strong>⇧ Shift</strong> and let go on <strong>MP4</strong>, <strong>MP3</strong>, <strong>M4A</strong> or <strong>WAV</strong>; the file lands in Downloads. Free and open source, on your Mac.",
        "how": "save a video from a link",
        "steps": [
            "Open the video in your browser: a YouTube video or Short, a post on X, a Threads post.",
            "Press on the address in the address bar and drag it out (or drag a link or thumbnail from a page).",
            "Press <strong>⇧ Shift</strong>. The Convert wheel opens with MP4, MP3, M4A and WAV.",
            "Let go on a format. The file is saved in Downloads, named after the post.",
        ],
        "more_title": "Which links work",
        "more": [
            "<strong>YouTube</strong>: youtube.com/watch, Shorts, live and youtu.be links.",
            "<strong>X (Twitter)</strong>: x.com and twitter.com posts with a video.",
            "<strong>Threads</strong>: threads.com and threads.net posts; these need nothing extra.",
            "<strong>Instagram</strong> and <strong>TikTok</strong>: see their own guides.",
        ] + LINK_NOTES[:3] + ["Download only your own videos, or videos whose owner allows it; YouTube’s terms allow downloads only where YouTube offers them."],
        "faq": [
            ("Can I save a YouTube video as MP3?", "Yes. Drag its address, press ⇧ Shift and let go on MP3."),
            ("Where does the file go?", "Into your Downloads folder, named after the post. It also shows up on YummyOrange’s shelf or Clothesline, like any new file."),
            ("Is it free?", "Yes, free and open source under the MIT licence."),
        ],
        "related": ["download-instagram-videos-on-mac", "download-tiktok-videos-on-mac", "video-to-mp3-on-mac"],
    },
]
BY_SLUG = {g["slug"]: g for g in GUIDES}
GROUPS = ["PDF", "Converting", "Video and audio", "Saving videos from links"]


def ld(obj):
    return '<script type="application/ld+json">' + json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "</script>"


def text(s):
    """Plain text of an HTML fragment (for JSON-LD and llms.txt)."""
    return html.unescape(re.sub(r"<[^>]+>", "", s))


def head(title, desc, path, extra=""):
    url = f"{SITE}/{path}".rstrip("/") if path else f"{SITE}/"
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>{html.escape(title)}</title>
  <meta name="description" content="{html.escape(desc)}">
  <link rel="canonical" href="{url}">
  <meta name="color-scheme" content="light dark">
  <meta name="theme-color" content="#FBF8F5" media="(prefers-color-scheme: light)">
  <meta name="theme-color" content="#141113" media="(prefers-color-scheme: dark)">
  <meta property="og:type" content="article">
  <meta property="og:site_name" content="YummyOrange">
  <meta property="og:title" content="{html.escape(title)}">
  <meta property="og:description" content="{html.escape(desc)}">
  <meta property="og:url" content="{url}">
  <meta property="og:image" content="{SITE}/assets/og-image.jpg">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta name="twitter:card" content="summary_large_image">
  <link rel="icon" type="image/png" sizes="64x64" href="assets/favicon-64.png">
  <link rel="apple-touch-icon" href="assets/apple-touch-icon.png">
  <link rel="stylesheet" href="css/site.css">
  <script src="js/config.js"></script>
  <script src="js/analytics.js" defer></script>
  {extra}
</head>
<body>
<a class="skip-link" href="#main">Skip to content</a>
<header class="topbar">
  <div class="wrap topbar-inner">
    <a class="brand" href="./" aria-label="YummyOrange home">
      <img src="assets/icon-256.webp" width="28" height="28" alt="">
      <span>YummyOrange</span>
    </a>
    <nav class="topnav" aria-label="Site">
      <a href="guides">Guides</a>
      <a href="./#faq">Questions</a>
    </nav>
    <a class="btn btn-small" href="downloads/YummyOrange.dmg" data-download><span class="dl-ready">Download</span></a>
  </div>
</header>
"""


FOOT = """
<footer class="footer">
  <div class="wrap footer-inner">
    <a class="brand" href="./"><img src="assets/icon-256.webp" width="24" height="24" alt="" loading="lazy"><span>YummyOrange</span></a>
    <nav class="footer-links" aria-label="Footer">
      <a href="./#download">Download</a>
      <a href="guides">Guides</a>
      <a href="release-notes.html">Release notes</a>
      <a href="privacy.html">Privacy policy</a>
      <a href="./#faq">Questions</a>
      <a data-config-mailto="supportEmail" hidden>Talk to the founder</a>
      <a href="https://github.com/furqan4545/yummyorange">GitHub</a>
    </nav>
    <p class="footer-legal"><span>© 2026 <a href="https://epoxlab.com">Epoxlab LLC</a>, maker of YummyOrange.</span> <span>Mac and macOS are trademarks of Apple Inc.</span></p>
  </div>
</footer>
<script src="js/site.js" defer></script>
</body>
</html>
"""

CTA = f"""  <div class="guide-cta">
    <a class="btn" href="downloads/YummyOrange.dmg" data-download><span class="dl-ready">Download YummyOrange</span></a>
    <p>{FACTS}</p>
  </div>
"""


def crumbs_ld(items):
    return {"@context": "https://schema.org", "@type": "BreadcrumbList",
            "itemListElement": [{"@type": "ListItem", "position": i + 1, "name": n, "item": u} for i, (n, u) in enumerate(items)]}


def faq_ld(pairs):
    return {"@context": "https://schema.org", "@type": "FAQPage",
            "mainEntity": [{"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": text(a)}} for q, a in pairs]}


def guide_page(g):
    url = f"{SITE}/{g['slug']}"
    data = [
        crumbs_ld([("YummyOrange", f"{SITE}/"), ("Guides", f"{SITE}/guides"), (g["h1"], url)]),
        faq_ld(g["faq"]),
        {"@context": "https://schema.org", "@type": "WebPage", "@id": url, "url": url, "name": g["title"],
         "description": g["desc"], "about": {"@id": APP_ID}, "dateModified": TODAY, "inLanguage": "en"},
    ]
    out = [head(g["title"], g["desc"], g["slug"], "\n  ".join(ld(d) for d in data))]
    out.append('\n<main id="main" class="wrap doc-page guide">\n')
    out.append(f'  <nav class="crumbs" aria-label="Breadcrumb"><a href="guides">Guides</a> <span aria-hidden="true">›</span> <span aria-current="page">{html.escape(g["group"])}</span></nav>\n')
    out.append(f'  <h1>{html.escape(g["h1"])}</h1>\n  <p class="doc-lede">{g["lede"]}</p>\n')
    out.append(CTA)
    out.append(f'\n  <h2>How to {g["how"]} on a Mac</h2>\n  <ol class="steps">\n')
    out += [f"    <li>{s}</li>\n" for s in g["steps"]]
    out.append("  </ol>\n")
    if g.get("table"):
        out.append('\n  <h2>Every format, at a glance</h2>\n  <div class="guide-table-wrap"><table class="guide-table">\n    <thead><tr><th scope="col">Drop a…</th><th scope="col">and get</th></tr></thead>\n    <tbody>\n')
        out += [f"      <tr><th scope=\"row\">{html.escape(a)}</th><td>{html.escape(b)}</td></tr>\n" for a, b in g["table"]]
        out.append("    </tbody>\n  </table></div>\n")
    if g.get("more"):
        out.append(f'\n  <h2>{html.escape(g["more_title"])}</h2>\n  <ul class="doc-list">\n')
        out += [f"    <li>{m}</li>\n" for m in g["more"]]
        out.append("  </ul>\n")
    out.append('\n  <h2>Questions</h2>\n  <div class="faq">\n')
    for q, a in g["faq"]:
        out.append(f"    <details>\n      <summary>{html.escape(q)}</summary>\n      <p>{a}</p>\n    </details>\n")
    out.append("  </div>\n")
    out.append('\n  <h2>More guides</h2>\n  <ul class="guide-links">\n')
    for s in g["related"]:
        r = BY_SLUG[s]
        out.append(f'    <li><a href="{s}"><strong>{html.escape(r["h1"])}</strong><span>{html.escape(r["short"])}</span></a></li>\n')
    out.append('  </ul>\n  <p class="guide-all"><a href="guides">All guides</a></p>\n</main>\n')
    out.append(FOOT)
    return "".join(out)


def hub_page():
    title = "Guides: convert, edit, compress and download files on a Mac – YummyOrange"
    desc = "Step-by-step guides for everyday file jobs on a Mac with YummyOrange: edit PDF text, PDF to Word, HEIC to JPG, MOV to MP4, compress, trim, and save videos from Instagram, TikTok and YouTube."
    data = [crumbs_ld([("YummyOrange", f"{SITE}/"), ("Guides", f"{SITE}/guides")]),
            {"@context": "https://schema.org", "@type": "ItemList", "name": "YummyOrange guides",
             "itemListElement": [{"@type": "ListItem", "position": i + 1, "url": f"{SITE}/{g['slug']}", "name": g["h1"]} for i, g in enumerate(GUIDES)]}]
    out = [head(title, desc, "guides", "\n  ".join(ld(d) for d in data))]
    out.append('\n<main id="main" class="wrap doc-page guide">\n  <h1>Guides</h1>\n')
    out.append('  <p class="doc-lede">Everyday file jobs on a Mac, done the YummyOrange way: drag a file (or a link), press a key, and let go on what you want. Free and open source, on your Mac.</p>\n')
    out.append(CTA)
    for grp in GROUPS:
        out.append(f'\n  <h2>{html.escape(grp)}</h2>\n  <ul class="guide-links">\n')
        for g in [g for g in GUIDES if g["group"] == grp]:
            out.append(f'    <li><a href="{g["slug"]}"><strong>{html.escape(g["h1"])}</strong><span>{html.escape(g["short"])}</span></a></li>\n')
        out.append("  </ul>\n")
    out.append("</main>\n")
    out.append(FOOT)
    return "".join(out)


def sitemap():
    pages = [("", "1.0"), ("guides", "0.8")] + [(g["slug"], "0.8") for g in GUIDES] + [("release-notes", "0.5"), ("privacy", "0.3"), ("licenses/ffmpeg", "0.2")]
    rows = "".join(f"  <url><loc>{SITE}/{p}</loc><lastmod>{TODAY}</lastmod><priority>{pr}</priority></url>\n" for p, pr in pages)
    return f'<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n{rows}</urlset>\n'


ROBOTS = f"""# yummyorange.com: everything here is public, and search engines and AI assistants are welcome to read it.
User-agent: *
Allow: /

# Named so it's clear they are welcome (AI search and assistants).
User-agent: GPTBot
User-agent: OAI-SearchBot
User-agent: ChatGPT-User
User-agent: ClaudeBot
User-agent: Claude-SearchBot
User-agent: Claude-User
User-agent: PerplexityBot
User-agent: Perplexity-User
User-agent: Google-Extended
User-agent: Applebot-Extended
User-agent: Bingbot
User-agent: DuckAssistBot
User-agent: Meta-ExternalAgent
User-agent: MistralAI-User
Allow: /

Sitemap: {SITE}/sitemap.xml
"""


def llms_txt():
    lines = [
        "# YummyOrange",
        "",
        "> YummyOrange is a free, open-source (MIT) menu-bar app for the Mac that converts, edits, compresses and downloads files with one gesture: start dragging a file (or a link from a browser), press a modifier key, and a wheel of options opens under the pointer; let go on one and the new file is saved next to the original. Made by Epoxlab LLC. macOS 13 Ventura or later, Apple silicon, about 7 MB. Everything runs on the Mac; files are never uploaded.",
        "",
        "Key facts:",
        "- Price: free. Licence: MIT. Source: https://github.com/furqan4545/yummyorange",
        "- Download: https://yummyorange.com/downloads/YummyOrange.dmg (notarized by Apple; updates itself)",
        "- The gesture: drag a file, press ⇧ Shift (Convert wheel: file formats), ⌘ Command (Tools wheel: compress, edit, trim, PDF tools) or ⌥ Option (Actions wheel: copy, AirDrop, zip, move).",
        "- Results are saved next to the original as new files; the original is never changed. New files can appear on a shelf near the pointer or on the Clothesline, a line of cards under the MacBook notch.",
        "- Converts images (JPG, PNG, HEIC, WebP, TIFF, AVIF, GIF, BMP, PDF), video (MP4, MOV, MKV, WebM, AVI, WMV, GIF, MP3), audio (MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA), PDF (to DOCX, TXT, Markdown, EPUB, PPTX, XLSX, PNG, JPG, SVG), documents (DOCX, DOC, RTF, HTML, TXT, Markdown, ODT, Pages to PDF and each other), spreadsheets (XLSX, XLS, ODS, CSV, TSV), slides (PPTX, PPT) and subtitles (SRT, VTT).",
        "- PDF tools: Edit PDF (change a line's text in place in its own font, add text), Organize pages, Merge, Split Pages, Compress, Compress to a size, Add/Remove Password, PDF/A, Extract Text (with OCR).",
        "- Image tools: Compress, Compress to a size, Resize, Crop, Annotate, Redact, Add Background, Remove background, Strip Metadata, Read QR Code, Collage, Make PDF.",
        "- Video and audio tools: frame-accurate Trim, Split, Merge, Crop, Speed, Mute, Extract Audio, Normalize, Bleep, Redact, Snapshot, Visualize.",
        "- Saves videos or their sound (MP4, MP3, M4A, WAV) from links to YouTube, X (Twitter), Instagram, TikTok and Threads: drag the address out of the browser's address bar, press ⇧ Shift, let go on a format; the file goes to Downloads. Uses yt-dlp, downloaded once with the user's consent.",
        "- Privacy: the app has no account, no analytics and sends nothing about the user or their files. The website uses PostHog analytics.",
        "",
        "## Guides",
        "",
    ]
    lines += [f"- [{g['h1']}]({SITE}/{g['slug']}): {text(g['desc'])}" for g in GUIDES]
    lines += [
        "",
        "## More",
        "",
        f"- [Home page, with live demos and questions]({SITE}/): what YummyOrange does and how the wheel works",
        f"- [Release notes]({SITE}/release-notes): every version and what changed",
        f"- [Privacy policy]({SITE}/privacy): what the app and the website do with data",
        "- [Source code on GitHub](https://github.com/furqan4545/yummyorange)",
        "",
    ]
    return "\n".join(lines)


def home_ld(page):
    """The home page's structured data: who makes it, the app itself (version from js/config.js), and its questions,
    taken from the page's own FAQ so the two never disagree."""
    config = (PUBLIC / "js" / "config.js").read_text(encoding="utf-8")
    version = re.search(r'version:\s*"([^"]+)"', config).group(1)
    faq_html = page[page.index('id="faq"'):]
    faq = [(text(q).strip(), re.sub(r"\s+", " ", text(a)).strip())
           for q, a in re.findall(r"<details[^>]*>\s*<summary[^>]*>(.*?)</summary>(.*?)</details>", faq_html, re.S)]
    org = {"@type": "Organization", "@id": f"{SITE}/#org", "name": "Epoxlab LLC", "url": "https://epoxlab.com",
           "brand": {"@type": "Brand", "name": "YummyOrange"}}
    app = {
        "@type": "SoftwareApplication", "@id": APP_ID, "name": "YummyOrange", "url": f"{SITE}/",
        "description": "A free, open-source menu-bar app for the Mac: start dragging a file (or a link from a browser), press a key, and a wheel of formats and tools opens under the pointer. Converts images, video, audio, PDFs and documents, edits PDF text, compresses, trims, and saves videos from YouTube, X, Instagram, TikTok and Threads.",
        "applicationCategory": "UtilitiesApplication", "operatingSystem": "macOS 13 Ventura or later (Apple silicon)",
        "softwareVersion": version, "fileSize": "7 MB", "downloadUrl": f"{SITE}/downloads/YummyOrange.dmg",
        "releaseNotes": f"{SITE}/release-notes", "image": f"{SITE}/assets/icon-256.webp", "screenshot": f"{SITE}/assets/og-image.jpg",
        "isAccessibleForFree": True, "license": "https://opensource.org/licenses/MIT",
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
        "author": {"@id": f"{SITE}/#org"}, "publisher": {"@id": f"{SITE}/#org"},
        "sameAs": ["https://github.com/furqan4545/yummyorange"],
        "featureList": [
            "Convert images: JPG, PNG, HEIC, WebP, TIFF, AVIF, GIF, BMP, PDF",
            "Convert video: MP4, MOV, MKV, WebM, AVI, WMV, GIF, MP3",
            "Convert audio: MP3, M4A, WAV, FLAC, OGG, Opus, AIFF",
            "PDF to Word (DOCX), TXT, Markdown, EPUB, PPTX, XLSX and images",
            "Edit PDF text in the PDF's own font; organize, merge, split, compress and password-protect PDFs",
            "Compress files, or compress to a size in MB",
            "Frame-accurate video and audio trimming, splitting and merging",
            "Save videos or their sound from YouTube, X, Instagram, TikTok and Threads links",
            "Everything runs on the Mac; nothing is uploaded",
        ],
    }
    site = {"@type": "WebSite", "@id": f"{SITE}/#site", "url": f"{SITE}/", "name": "YummyOrange", "publisher": {"@id": f"{SITE}/#org"}}
    faq_page = {"@type": "FAQPage", "mainEntity": [{"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}} for q, a in faq]}
    return ld({"@context": "https://schema.org", "@graph": [org, site, app, faq_page]}), len(faq)


def home_guides():
    items = "".join(f'      <li><a href="{g["slug"]}"><strong>{html.escape(g["h1"])}</strong><span>{html.escape(g["short"])}</span></a></li>\n' for g in GUIDES)
    return f"""<section class="section wrap guides-home" id="guides" aria-labelledby="guides-title">
    <header class="section-head">
      <h2 id="guides-title">Guides for everyday jobs</h2>
      <p>Step by step, for the things people do most: edit a PDF, change a format, make a file smaller, save a video.</p>
    </header>
    <ul class="guide-links">
{items}    </ul>
  </section>"""


def update_home():
    path = PUBLIC / "index.html"
    page = path.read_text(encoding="utf-8")
    data, n = home_ld(page)
    page = re.sub(r"<!-- ld:start \(tools/make-guides.py\) -->.*?<!-- ld:end -->",
                  lambda _: f"<!-- ld:start (tools/make-guides.py) -->{data}<!-- ld:end -->", page, flags=re.S)
    page = re.sub(r"<!-- guides:start \(tools/make-guides.py\) -->.*?<!-- guides:end -->",
                  lambda _: f"<!-- guides:start (tools/make-guides.py) -->\n  {home_guides()}\n  <!-- guides:end -->", page, flags=re.S)
    path.write_text(page, encoding="utf-8")
    return n


def main():
    for g in GUIDES:
        (PUBLIC / f"{g['slug']}.html").write_text(guide_page(g), encoding="utf-8")
    (PUBLIC / "guides.html").write_text(hub_page(), encoding="utf-8")
    (PUBLIC / "sitemap.xml").write_text(sitemap(), encoding="utf-8")
    (PUBLIC / "robots.txt").write_text(ROBOTS, encoding="utf-8")
    (PUBLIC / "llms.txt").write_text(llms_txt(), encoding="utf-8")
    questions = update_home()
    print(f"wrote {len(GUIDES)} guides, guides.html, sitemap.xml, robots.txt, llms.txt; home page: guides list and structured data ({questions} questions)")


if __name__ == "__main__":
    main()
