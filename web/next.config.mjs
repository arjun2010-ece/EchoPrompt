/** @type {import('next').NextConfig} */
const nextConfig = {
  // The bottom-left Next.js badge is useful while developing framework
  // internals, but it obscures the product preview in this marketing site.
  // Build and runtime errors remain visible in the browser.
  devIndicators: false,
  // This project intentionally lives inside the native-app repository. Keep
  // Next.js file tracing scoped to this web project even if a parent folder
  // contains another package-manager lockfile.
  outputFileTracingRoot: new URL(".", import.meta.url).pathname,
};

export default nextConfig;
