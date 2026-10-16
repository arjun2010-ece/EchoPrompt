import type { MetadataRoute } from "next";

const configuredSiteUrl = process.env.NEXT_PUBLIC_SITE_URL?.trim().replace(/\/+$/, "");
const siteUrl = configuredSiteUrl ?? (process.env.NODE_ENV === "development" ? "http://localhost:3000" : undefined);

export default function robots(): MetadataRoute.Robots {
  return {
    rules: {
      userAgent: "*",
      allow: "/",
    },
    sitemap: siteUrl ? `${siteUrl}/sitemap.xml` : undefined,
  };
}
