---
allowed-tools: Read, Write, MultiEdit, Bash
description: Generate a new React component with TypeScript, Tailwind CSS, and shadcn/ui integration for the Modern Business template
---

# /component - Generate New UI Component

Generate a new React component with TypeScript, Tailwind CSS, and shadcn/ui integration for the Modern Business template.

## Usage

```
/component ComponentName [--type=retail|service|shared] [--form] [--test]
```

## Examples

```
/component ProductCard --type=retail
/component ServiceBookingForm --type=service --form --test
/component NavigationMenu --type=shared
```

## What this command does:

1. **Creates component file** in the appropriate directory:
   - E-commerce/retail components: `src/components/shop/`
   - Service/booking components: `src/components/booking/`
   - Shared components: `src/components/layout/`

2. **Generates TypeScript interface** with proper props definition

3. **Adds Tailwind CSS styling** with responsive design

4. **Integrates shadcn/ui components** where appropriate

5. **Includes accessibility features** (ARIA labels, semantic HTML)

6. **Creates form validation** with Zod schemas (if --form flag)

7. **Generates test file** with React Testing Library (if --test flag)

## Component Template Structure:

```tsx
interface ComponentNameProps {
  // Props definition
}

export default function ComponentName({ prop1, prop2 }: ComponentNameProps): JSX.Element {
  // Component logic

  return (
    <div className="tailwind-classes">
      {/* Component JSX */}
    </div>
  )
}
```

## Business-Specific Features:

### Coffee Shop Components (--type=coffee)
- Product display with variants (size, milk type)
- Order customization interfaces
- Loyalty points display
- POS-friendly layouts

### Yoga Studio Components (--type=yoga)
- Class booking interfaces
- Membership management
- Instructor profiles
- Schedule displays

### Shared Components (--type=shared)
- Navigation and layout
- Authentication forms
- Payment components
- Admin interfaces

## Files Created:
- `src/components/[category]/ComponentName.tsx`
- `src/components/[category]/ComponentName.test.tsx` (if --test)
- Updates to component exports if needed