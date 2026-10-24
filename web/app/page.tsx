// This is intentionally a request-time Server Component. The marketing site
// has no client-side data dependency, but deploying it as dynamic SSR keeps
// the rendering model ready for server-provided release details or content.
export const dynamic = "force-dynamic";

const modes = [
  {
    number: "01",
    name: "Normal",
    eyebrow: "Set the rhythm",
    text: "Choose a comfortable reading pace, then let the script move smoothly while you focus on the delivery.",
    detail: "Live text size and line spacing controls",
  },
  {
    number: "02",
    name: "Voice",
    eyebrow: "Speak naturally",
    text: "EchoPrompter follows the words you say, pauses when you pause, and keeps the next line waiting for you.",
    detail: "Active word tracking with clear reading feedback",
  },
  {
    number: "03",
    name: "Recorded audio",
    eyebrow: "Rehearse in sync",
    text: "Play a local voice-over or rehearsal recording and let the prompter follow its recognized words.",
    detail: "Local audio playback with synchronized progress",
  },
];

const questions = [
  {
    question: "Does EchoPrompter work only on macOS?",
    answer:
      "Yes. EchoPrompter is a native macOS app built for macOS 13 Ventura and later. The website explains the desktop product and links visitors to its releases.",
  },
  {
    question: "When does it ask for microphone access?",
    answer:
      "Only Voice mode needs microphone access. Normal scrolling does not request microphone or speech recognition access. Recorded Audio mode uses speech recognition to align a chosen local file with its script.",
  },
  {
    question: "Can I keep the prompt over another app?",
    answer:
      "Yes. The prompt is a floating macOS window. Enable Click through prompt when you need to interact with the application beneath it while you read.",
  },
  {
    question: "Where are my scripts saved?",
    answer:
      "Scripts are saved locally as readable text files in Documents/EchoPrompter Scripts. The app does not require an account or its own cloud-storage service.",
  },
];

const structuredData = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "SoftwareApplication",
      name: "EchoPrompter",
      applicationCategory: "ProductivityApplication",
      operatingSystem: "macOS 13 Ventura or later",
      description:
        "A native macOS teleprompter with smooth scrolling, live voice following, and recorded-audio script synchronization.",
      featureList: [
        "Smooth normal teleprompter scrolling",
        "Live voice-controlled script following",
        "Recorded-audio synchronized script following",
        "Adjustable text size and line spacing",
        "Local plain-text script storage",
        "Floating click-through prompt window",
      ],
    },
    {
      "@type": "FAQPage",
      mainEntity: questions.map(({ question, answer }) => ({
        "@type": "Question",
        name: question,
        acceptedAnswer: {
          "@type": "Answer",
          text: answer,
        },
      })),
    },
  ],
};

export default function Home() {
  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{
          __html: JSON.stringify(structuredData).replace(/</g, "\\u003c"),
        }}
      />
    <main>
      <section className="hero" id="top">
        <nav className="nav shell" aria-label="Primary navigation">
          <a className="brand" href="#top" aria-label="EchoPrompter home">
            <span className="brand-mark" aria-hidden="true"><img src="/icon.png" alt="" /></span>
            <span>EchoPrompter</span>
          </a>
          <div className="nav-links">
            <a href="#modes">Modes</a>
            <a href="#workflow">Workflow</a>
            <a href="#faq">FAQ</a>
          </div>
          <a className="nav-cta" href="#download">Get for macOS <span aria-hidden="true">↗</span></a>
        </nav>

        <div className="hero-grid shell">
          <div className="hero-copy">
            <p className="kicker"><span /> Native macOS teleprompter</p>
            <h1>Stay on script.<br /><em>Stay present.</em></h1>
            <p className="hero-description">
              A thoughtful teleprompter for the moments when your delivery matters more than your controls.
            </p>
            <div className="hero-actions">
              <a className="button button-primary" href="#download">Download EchoPrompter <span aria-hidden="true">↓</span></a>
              <a className="button button-quiet" href="#workflow">See how it works <span aria-hidden="true">→</span></a>
            </div>
            <div className="availability" aria-label="Product availability">
              <span className="availability-dot" /> Built for macOS 13+
              <span className="availability-rule" /> No account required
            </div>
          </div>

          <div className="prompt-stage" aria-label="EchoPrompter interface preview">
            <div className="orb orb-one" />
            <div className="orb orb-two" />
            <div className="prompt-window">
              <div className="window-titlebar">
                <span className="traffic"><b /><b /><b /></span>
                <span className="window-app-brand"><img src="/icon.png" alt="" />EchoPrompter</span>
                <span className="window-status">VOICE CONTROL</span>
              </div>
              <div className="window-reading">
                <p>Every clear message begins with a moment of focus.</p>
                <p>Let your ideas <mark>move at your pace,</mark> so your audience sees you, not the script.</p>
              </div>
              <div className="window-controls">
                <span className="control-pill">↙<small>Slower</small></span>
                <span className="control-play">Ⅱ <small>Listening</small></span>
                <span className="control-pill">↗<small>Faster</small></span>
              </div>
            </div>
            <p className="stage-caption"><span /> Live word following, without the rush</p>
          </div>
        </div>
        <div className="hero-baseline" />
      </section>

      <section className="intro shell" id="workflow">
        <p className="section-label">A more natural reading experience</p>
        <div className="intro-grid">
          <h2>Built to disappear<br />when it matters.</h2>
          <div>
            <p>
              EchoPrompter gives your words a calm, considered place to live—close to the camera, above the work you are sharing, and ready when you are.
            </p>
            <a className="text-link" href="#modes">Explore the ways to present <span aria-hidden="true">→</span></a>
          </div>
        </div>
        <div className="workflow-steps">
          <article><span>01</span><h3>Write</h3><p>Paste a draft, refine your language, and save it locally as a readable text file.</p></article>
          <article><span>02</span><h3>Choose</h3><p>Select a pace that suits the moment: automatic, live voice, or recorded audio.</p></article>
          <article><span>03</span><h3>Present</h3><p>Open the floating prompt, keep it near your camera, and give your attention to the room.</p></article>
        </div>
      </section>

      <section className="modes-section" id="modes">
        <div className="shell">
          <div className="section-heading">
            <p className="section-label">One script, three rhythms</p>
            <h2>Follow the method<br />that fits the moment.</h2>
          </div>
          <div className="mode-list">
            {modes.map((mode) => (
              <article className="mode-card" key={mode.name}>
                <span className="mode-number">{mode.number}</span>
                <div className="mode-main">
                  <p className="mode-eyebrow">{mode.eyebrow}</p>
                  <h3>{mode.name}</h3>
                  <p>{mode.text}</p>
                </div>
                <p className="mode-detail"><span>✦</span>{mode.detail}</p>
              </article>
            ))}
          </div>
        </div>
      </section>

      <section className="customize shell">
        <div className="customize-copy">
          <p className="section-label">Made for your line of sight</p>
          <h2>Your words,<br /><em className="customize-emphasis">your way.</em></h2>
          <p>Set the size, spacing, contrast, and presentation style that lets you read comfortably without breaking eye contact.</p>
          <ul>
            <li><span>↗</span> Text size from 16 to 110 pt</li>
            <li><span>↗</span> Adjustable line spacing and prompt opacity</li>
            <li><span>↗</span> Midnight, Paper, and Ember prompt themes</li>
            <li><span>↗</span> Mirror text for teleprompter glass</li>
          </ul>
        </div>
        <div className="style-preview" aria-label="Prompt customization preview">
          <div className="preview-topline"><span>Prompt appearance</span><b>◐</b></div>
          <div className="preview-script">
            <p>Make every <span>word</span> feel like your own.</p>
            <i />
            <p className="muted-line">Find your rhythm, then let the thought land.</p>
          </div>
          <div className="preview-settings">
            <div><span>Text size</span><b>50 pt</b><i><em /></i></div>
            <div><span>Line spacing</span><b>1.28×</b><i><em /></i></div>
          </div>
        </div>
      </section>

      <section className="privacy-band">
        <div className="shell privacy-grid">
          <div className="privacy-icon" aria-hidden="true">⌁</div>
          <div>
            <p className="section-label">A quieter kind of software</p>
            <h2>Your script stays close.</h2>
          </div>
          <p>EchoPrompter stores scripts on your Mac, asks for permissions only for the mode that needs them, and never requires an account to get started.</p>
        </div>
      </section>

      <section className="faq shell" id="faq">
        <div className="faq-heading">
          <p className="section-label">Good to know</p>
          <h2>Questions, answered.</h2>
        </div>
        <div className="faq-list">
          {questions.map((item, index) => (
            <details key={item.question} open={index === 0}>
              <summary>{item.question}<span aria-hidden="true">+</span></summary>
              <p>{item.answer}</p>
            </details>
          ))}
        </div>
      </section>

      <section className="download" id="download">
        <div className="shell download-inner">
          <p className="section-label">Ready when you are</p>
          <h2>Bring your next<br /><em>great take</em> closer.</h2>
          <p>Download the native macOS app, open your script, and make space for the delivery.</p>
          <a className="button button-primary" href="https://github.com/arjun2010-ece/EchoPrompt/releases/latest">Get EchoPrompter for macOS <span aria-hidden="true">↗</span></a>
          <small>macOS 13 Ventura or later · Personal-use license</small>
        </div>
      </section>

      <footer className="footer">
        <div className="shell footer-inner">
          <div className="footer-branding">
            <a className="brand" href="#top"><span className="brand-mark" aria-hidden="true"><img src="/icon.png" alt="" /></span><span>EchoPrompter</span></a>
            <p>Made in Portugal by Arjun Sah <span aria-hidden="true">·</span> © 2026 EchoPrompter</p>
          </div>
          <div className="footer-actions">
            <nav className="footer-links" aria-label="Footer navigation">
              <a href="#modes">Modes</a>
              <a href="#faq">FAQ</a>
              <a href="#top">Back to top ↑</a>
            </nav>
            {/*
              Replace this placeholder with the real channel URL when it is ready:
              <a className="footer-youtube" href="https://youtube.com/@your-channel" aria-label="EchoPrompter on YouTube">
                <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M21.6 7.2a2.9 2.9 0 0 0-2-2C17.8 4.7 12 4.7 12 4.7s-5.8 0-7.6.5a2.9 2.9 0 0 0-2 2A30 30 0 0 0 2 12a30 30 0 0 0 .4 4.8 2.9 2.9 0 0 0 2 2c1.8.5 7.6.5 7.6.5s5.8 0 7.6-.5a2.9 2.9 0 0 0 2-2A30 30 0 0 0 22 12a30 30 0 0 0-.4-4.8ZM9.7 15.3V8.7l5.7 3.3-5.7 3.3Z" /></svg>
              </a>
            */}
            <div className="footer-youtube-placeholder" role="img" aria-label="YouTube link coming soon">
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M21.6 7.2a2.9 2.9 0 0 0-2-2C17.8 4.7 12 4.7 12 4.7s-5.8 0-7.6.5a2.9 2.9 0 0 0-2 2A30 30 0 0 0 2 12a30 30 0 0 0 .4 4.8 2.9 2.9 0 0 0 2 2c1.8.5 7.6.5 7.6.5s5.8 0 7.6-.5a2.9 2.9 0 0 0 2-2A30 30 0 0 0 22 12a30 30 0 0 0-.4-4.8ZM9.7 15.3V8.7l5.7 3.3-5.7 3.3Z" /></svg>
              <span>Coming soon</span>
            </div>
          </div>
        </div>
      </footer>
    </main>
    </>
  );
}
