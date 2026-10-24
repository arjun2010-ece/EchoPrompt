Add something like this also# EchoPrompter web

The server-rendered Next.js marketing site for EchoPrompter. It is intentionally contained in `web/` so it can be deployed independently of the native macOS Swift app at the repository root.

## Local development

```sh
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Production build

```sh
npm run build
npm run start
```

## Deploy from GitHub

The simplest deployment path is Vercel:

1. Push this repository to GitHub.
2. Import the repository in Vercel.
3. Set the **Root Directory** to `web`.
4. Keep the detected Next.js build settings and deploy.
5. The download button already points to this repository’s GitHub Releases page. Publish a release when the native app bundle is ready.

The homepage is server rendered by default: `app/page.tsx` is a Next.js Server Component and does not require client-side JavaScript for its primary content or FAQ interactions.

## Search metadata

The site includes a descriptive title, product-focused metadata, structured data for the application and FAQ, crawler rules, a sitemap, and a native browser-tab icon.

Before deploying, set this environment variable in your host (for example, Vercel):

```sh
NEXT_PUBLIC_SITE_URL=https://your-domain.example
```

Use your final canonical HTTPS URL without a trailing slash. This enables the canonical URL and includes the sitemap location in `robots.txt`; the site intentionally does not guess a production domain. During `npm run dev`, the sitemap uses `http://localhost:3000` so it remains inspectable locally.
