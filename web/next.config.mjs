/** @type {import('next').NextConfig} */
const nextConfig = {
  // This project intentionally lives inside the native-app repository. Keep
  // Next.js file tracing scoped to this web project even if a parent folder
  // contains another package-manager lockfile.
  outputFileTracingRoot: new URL(".", import.meta.url).pathname,
};

export default nextConfig;
