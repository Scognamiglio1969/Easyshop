"use client";

import { useState } from "react";

const releaseURL =
  "https://github.com/Scognamiglio1969/Easyshop/releases/download/v0.1.0-alpha/Easyshop-0.1.0-alpha.dmg";
const githubURL = "https://github.com/Scognamiglio1969/Easyshop";

const tour = [
  {
    kicker: "01 · Select",
    title: "Point. Glow. Done.",
    text: "On-device Vision finds the subject and draws a living edge around it. Feather, expand or invert without leaving the canvas.",
    action: "Select subject",
  },
  {
    kicker: "02 · Shape",
    title: "Edit where you look.",
    text: "Light, colour and local corrections surface beside the image, then disappear. Every result becomes an editable layer or mask.",
    action: "Enhance locally",
  },
  {
    kicker: "03 · Deliver",
    title: "Every size. No friction.",
    text: "Resize the image or canvas, preserve ratios, choose resampling and export the format the job needs.",
    action: "Export artwork",
  },
];

const features = [
  ["✦", "Honest on-device ML", "Apple Vision powers subject and face detection. Every ML result stays inspectable as a layer or mask, with its provenance stated in the interface."],
  ["◇", "Real layers", "Raster, text and adjustment layers with masks, opacity, blend modes and a non-destructive native project."],
  ["◐", "Colour with intent", "Exposure, highlights, shadows, HSL, temperature, tint, curves, RGB balance, clarity and detail."],
  ["↔", "Resize everything", "Pixels, percentages, DPI, aspect lock, nine-point canvas anchors, crop and pro resampling methods."],
  ["Aa", "Editable type", "Write directly into the composition while keeping typography on its own editable layer."],
  ["↕", "A movable workspace", "Drag, collapse or dismiss the tool and inspector islands. The interface follows the work, then gives the photograph its space back."],
];

export default function Home() {
  const [tourStep, setTourStep] = useState(0);

  return (
    <main>
      <nav className="nav shell">
        <a className="brand" href="#top" aria-label="Easyshop home">
          <img src="/assets/easyshop-icon.png" alt="" />
          <span>Easyshop</span>
          <i>OPEN SOURCE</i>
        </a>
        <div className="navlinks">
          <a href="#tour">Tour</a>
          <a href="#features">Features</a>
          <a href="#founder">Founder</a>
          <a href={githubURL}>GitHub</a>
        </div>
        <a className="nav-download" href={releaseURL}>Download for Mac <span>↓</span></a>
      </nav>

      <section className="hero shell" id="top">
        <div className="hero-copy">
          <div className="eyebrow"><span /> Native · Local · Open source</div>
          <h1>The photo editor<br /><em>that stays out of the photograph.</em></h1>
          <p className="hero-lede">
            Easyshop brings layers, colour, resizing and on-device Vision ML into a Liquid Glass workspace for macOS.
            Tools appear when they matter; assisted edits remain visible as layers or masks.
          </p>
          <div className="hero-actions">
            <a className="button primary" href={releaseURL}>Download Easyshop <span>macOS 14+</span></a>
            <a className="button ghost" href={githubURL}>View source on GitHub ↗</a>
          </div>
          <div className="trustline">
            <span>Alpha 0.1</span><b>·</b><span>Universal Mac app</span><b>·</b><span>MIT licensed</span>
          </div>
        </div>

        <div className="hero-visual" aria-label="Easyshop interactive product tour">
          <span className="concept-label">INTERACTIVE PRODUCT TOUR</span>
          <div className="orbit orbit-one" />
          <div className="orbit orbit-two" />
          <div className="app-window">
            <div className="window-top">
              <div className="traffic"><i /><i /><i /></div>
              <span>Summer portrait · 1536 × 1024</span>
              <button>Export</button>
            </div>
            <div className="canvas">
              <img src="/assets/demo-portrait.png" alt="Colourful portrait being edited in Easyshop" />
              <div className="tool-island"><span className="drag-mark">•••</span><b>↕</b><b>◇</b><b>◯</b><b>⌁</b><b className="active">✦</b><b>T</b></div>
              <div className="subject-glow" />
              <div className="selection-pill"><strong>✦ Subject ready</strong><span>Feather 2.0</span><span>Expand +1</span><button>Mask</button></div>
              <div className="vision-halo"><span>✦</span><i>Vision ML</i></div>
              <div className="float-actions">
                <button><b>⌁</b> Remove background</button>
                <button><b>◐</b> Enhance subject</button>
                <button><b>◇</b> Separate layers</button>
              </div>
              <div className="layers-island">
                <header><b>•••</b> LAYERS <span>3</span></header>
                <p><i>◐</i><b>Colour grade</b><small>Adjustment</small></p>
                <p><i>T</i><b>Campaign title</b><small>Text</small></p>
                <p><i>▣</i><b>Original portrait</b><small>Image</small></p>
              </div>
            </div>
          </div>
          <div className="hero-note"><strong>Everything floats.</strong><span>Nothing blocks the photograph.</span></div>
        </div>
      </section>

      <section className="manifesto">
        <div className="shell manifesto-inner">
          <p>PHOTO EDITING, DISTILLED</p>
          <h2>Keep the craft.<br /><em>Remove the friction.</em></h2>
          <div className="manifesto-copy">
            <p>Easyshop reveals tools only when they matter. Subject selection and local corrections stay visible as masks and layers you can inspect, refine or remove.</p>
            <p>No account. No forced cloud. No terminal for users. Just a fast, self-contained Mac app—and source code everyone can study.</p>
          </div>
        </div>
      </section>

      <section className="tour shell" id="tour">
        <div className="section-heading">
          <p>AN INTERFACE THAT MOVES WITH YOU</p>
          <h2>Three gestures from idea to image.</h2>
        </div>
        <div className="tour-grid">
          <div className="tour-nav">
            {tour.map((item, index) => (
              <button key={item.kicker} className={tourStep === index ? "selected" : ""} onClick={() => setTourStep(index)}>
                <span>{item.kicker}</span><strong>{item.title}</strong><i>↗</i>
              </button>
            ))}
          </div>
          <div className={`tour-stage step-${tourStep}`}>
            <div className="tour-photo"><img src="/assets/demo-portrait.png" alt="Easyshop interactive tour" /></div>
            <div className="tour-aura" />
            <div className="tour-orb">✦</div>
            <div className="tour-card">
              <span>{tour[tourStep].kicker}</span>
              <h3>{tour[tourStep].title}</h3>
              <p>{tour[tourStep].text}</p>
              <button>{tour[tourStep].action} <b>→</b></button>
            </div>
          </div>
        </div>
      </section>

      <section className="feature-section shell" id="features">
        <div className="section-heading split">
          <div><p>SMALL APP. SERIOUS TOOLSET.</p><h2>What you need.<br />Exactly where you need it.</h2></div>
          <p>Fast work should not mean fragile work. Easyshop keeps professional essentials editable while simplifying how you reach them.</p>
        </div>
        <div className="feature-grid">
          {features.map(([icon, title, text]) => (
            <article key={title}><i>{icon}</i><h3>{title}</h3><p>{text}</p></article>
          ))}
        </div>
      </section>

      <section className="formats">
        <div className="shell formats-inner">
          <div><p>OPEN IN. CREATE. SEND OUT.</p><h2>Open what macOS decodes. Deliver what the job needs.</h2></div>
          <div className="format-cloud"><b>PSD</b><b>TIFF</b><b>JPEG</b><b>PNG</b><b>HEIC</b><b>AVIF</b><b>PDF</b><b>RAW*</b><b>.easyshop</b></div>
          <small>* RAW and specialised formats depend on the decoders available in macOS. Easyshop clearly reports compatibility instead of hiding limitations.</small>
        </div>
      </section>

      <section className="founder shell" id="founder">
        <div className="founder-portrait">
          <img src="/assets/massimo-scognamiglio-founder.jpg" alt="Massimo Scognamiglio in his studio" />
          <div className="founder-glass-label"><b>Massimo Scognamiglio</b><span>Founder · Photographer · Artist</span></div>
        </div>
        <div className="founder-copy">
          <p>THE FOUNDER’S POINT OF VIEW</p>
          <blockquote>Thirty years behind the camera shaped one principle: great tools should protect attention, not compete for it.</blockquote>
          <p className="bio"><strong>Massimo Scognamiglio</strong> is an Italian multidisciplinary artist whose practice spans photography, visual art, technology, film and digital culture. An early pioneer of the World Wide Web, he has explored identity, memory and technological change since the mid-1990s, exhibiting in Italy and internationally.</p>
          <p className="bio">From his Rome studio, Le Petit Atelier, he develops open-source software and experiments with AI as an expansion of artistic vision—not a replacement for it. Easyshop distils what a photographer actually needs to stay focused on the result.</p>
        </div>
      </section>

      <section className="open-source">
        <div className="shell source-card">
          <div><p>BUILT IN THE OPEN</p><h2>Your editor should never become a cage.</h2><span>MIT licensed · auditable source · open project format · community roadmap</span></div>
          <div className="source-actions"><a className="button primary" href={githubURL}>Explore the repository ↗</a><a className="button ghost" href={`${githubURL}/issues`}>Join the roadmap</a></div>
        </div>
      </section>

      <section className="final-cta shell">
        <img src="/assets/easyshop-icon.png" alt="Easyshop" />
        <p>CREATE AT THE SPEED OF SEEING</p>
        <h2>Make the photograph.<br /><em>Forget the software.</em></h2>
        <a className="button primary large" href={releaseURL}>Download Easyshop 0.1 Alpha <span>Free & open source</span></a>
      </section>

      <footer className="shell">
        <a className="brand" href="#top"><img src="/assets/easyshop-icon.png" alt="" /><span>Easyshop</span></a>
        <p>The open-source photo editor for Mac that protects your attention.</p>
        <div><a href={githubURL}>GitHub</a><a href={`${githubURL}/blob/main/LICENSE`}>MIT License</a><a href={`${githubURL}/blob/main/SECURITY.md`}>Security</a></div>
        <small>© 2026 Massimo Scognamiglio. Easyshop is independent and is not affiliated with Adobe.</small>
      </footer>
    </main>
  );
}
