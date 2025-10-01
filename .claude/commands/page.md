---
allowed-tools: Read, Write, MultiEdit, Bash
description: Generate a new Astro page with React integration, proper SEO, and business-specific layouts for the Modern Business template
---

# /page - Build New Astro Page

Generate a new Astro page with React integration, proper SEO, and business-specific layouts for the Modern Business template.

## Usage

```
/page page-name [--type=retail|service|shared] [--layout=default|admin|auth] [--seo]
```

## Examples

```
/page catalog --type=retail --layout=default --seo
/page service-schedule --type=service --layout=default --seo
/page admin-dashboard --type=shared --layout=admin
```

## What this command does:

1. **Creates Astro page file** in `src/pages/[category]/`

2. **Integrates React components** with proper client directives

3. **Adds SEO optimization** with meta tags, structured data (if --seo flag)

4. **Includes proper layout** based on page type

5. **Sets up TypeScript** with proper type definitions

6. **Adds responsive design** with mobile-first approach

7. **Implements accessibility** features and semantic HTML

## Page Template Structure:

```astro
---
import Layout from '@/components/layout/Layout.astro'
import PageComponent from '@/components/[category]/PageComponent'

export interface Props {
  title?: string
}

const { title = 'Default Page Title' } = Astro.props
---

<Layout title={title} description="Page description for SEO">
  <PageComponent client:load />
</Layout>
```

## Business-Specific Pages:

### Coffee Shop Pages (--type=coffee)
- **Menu Display** - Product catalog with filtering
- **Online Ordering** - Shopping cart and checkout
- **Store Locator** - Multiple location support
- **Loyalty Program** - Points and rewards
- **Catering Services** - Bulk order management

### Yoga Studio Pages (--type=yoga)
- **Class Schedule** - Calendar view with booking
- **Membership Plans** - Pricing and benefits
- **Instructor Profiles** - Bio and specialties
- **Member Portal** - Account and booking management
- **Workshop Events** - Special event listings

### Shared Pages (--type=shared)
- **Authentication** - Login/signup flows
- **User Profile** - Account management
- **Admin Dashboard** - Business management
- **Analytics** - Reporting and insights
- **Settings** - System configuration

## Layout Options:

### Default Layout
- Header with navigation
- Main content area
- Footer with contact info
- Mobile-responsive design

### Admin Layout
- Sidebar navigation
- Dashboard widgets
- User management tools
- Analytics integration

### Auth Layout
- Centered form design
- Minimal navigation
- Brand consistency
- Security features

## SEO Features (--seo flag):
```astro
---
const seoData = {
  title: 'Page Title - Coffee & Yoga Studio',
  description: 'Page description optimized for search engines',
  keywords: ['coffee', 'yoga', 'wellness', 'local business'],
  ogImage: '/images/og-image.jpg',
  canonical: Astro.url.href
}
---

<meta property="og:title" content={seoData.title} />
<meta property="og:description" content={seoData.description} />
<meta property="og:image" content={seoData.ogImage} />
<meta name="twitter:card" content="summary_large_image" />
<link rel="canonical" href={seoData.canonical} />

<!-- Structured Data for Local Business -->
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "LocalBusiness",
  "name": "Coffee & Yoga Studio",
  "description": seoData.description
}
</script>
```

## Performance Optimization:
- **Client directives** for React components (`client:load`, `client:visible`)
- **Image optimization** with Astro's built-in features
- **CSS optimization** with Tailwind purging
- **JavaScript bundling** with proper code splitting

## Files Created:
- `src/pages/[category]/page-name.astro`
- `src/components/[category]/PageComponent.tsx` (if complex logic needed)
- Updated navigation links (if applicable)