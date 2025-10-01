---
name: fire-init-agent
description: setep firebase project with auth and db
tools: Read, Write, MultiEdit, Bash, context7, playwright, shadcn-ui, firecrawl-mcp, taskmaster-ai, firebase
---

# Next.js + Firebase Hello World Deployment Checklist

## Prerequisites

- [ ] Node.js installed (v18 or higher recommended)
- [ ] npm or yarn package manager
- [ ] Firebase CLI installed (`npm install -g firebase-tools`)
- [ ] Firebase MCP configured
- [ ] Code editor (VS Code recommended)
- [ ] Git installed (optional but recommended)

## 1. Firebase Setup

### Firebase Console

- [ ] Create a new Firebase project at [console.firebase.google.com](https://console.firebase.google.com)
- [ ] Note down your project ID
- [ ] Enable Authentication
  - [ ] Go to Authentication → Sign-in method
  - [ ] Enable Email/Password (or your preferred method)
- [ ] Enable Firestore Database
  - [ ] Go to Firestore Database
  - [ ] Create database (start in test mode for development)
  - [ ] Select region closest to your users
- [ ] Register your web app
  - [ ] Go to Project Settings → General
  - [ ] Add a web app
  - [ ] Copy the Firebase configuration object

### Firebase CLI

- [ ] Login to Firebase CLI: `firebase login`
- [ ] Initialize Firebase in your project directory: `firebase init`
  - [ ] Select Firestore
  - [ ] Select Hosting
  - [ ] Choose your project
  - [ ] Accept default Firestore rules file
  - [ ] Accept default Firestore indexes file
  - [ ] Set public directory as `out` (for Next.js static export)
  - [ ] Configure as single-page app: No
  - [ ] Set up automatic builds: No

## 2. Next.js Project Setup

### Initialize Project

- [ ] Create Next.js app: `npx create-next-app@latest hello-world-firebase`
- [ ] Navigate to project: `cd hello-world-firebase`
- [ ] Install Firebase SDK: `npm install firebase`
- [ ] Install additional dependencies if needed:
  ```bash
  npm install react-firebase-hooks  # Optional: for easier Firebase hooks
  ```

### Project Structure

- [ ] Create `/lib` directory for Firebase configuration
- [ ] Create `/components` directory for reusable components
- [ ] Create `/context` directory for auth context (if using)

## 3. Firebase Configuration in Next.js

### Environment Variables

- [ ] Create `.env.local` file in root directory
- [ ] Add Firebase configuration:
  ```
  NEXT_PUBLIC_FIREBASE_API_KEY=your-api-key
  NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=your-auth-domain
  NEXT_PUBLIC_FIREBASE_PROJECT_ID=your-project-id
  NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET=your-storage-bucket
  NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID=your-sender-id
  NEXT_PUBLIC_FIREBASE_APP_ID=your-app-id
  ```
- [ ] Add `.env.local` to `.gitignore`

### Firebase Initialization

- [ ] Create `/lib/firebase.js` file
- [ ] Initialize Firebase app
- [ ] Export auth and db instances
- [ ] Test connection in development

## 4. Implement Features

### Authentication

- [ ] Create sign-up component
- [ ] Create login component
- [ ] Create logout functionality
- [ ] Implement auth state persistence
- [ ] Add protected routes (if needed)
- [ ] Test authentication flow

### Database Integration

- [ ] Create data model/schema
- [ ] Implement CRUD operations:
  - [ ] Create/Add documents
  - [ ] Read/Fetch documents
  - [ ] Update documents
  - [ ] Delete documents
- [ ] Add real-time listeners (if needed)
- [ ] Test database operations

### Hello World Page

- [ ] Create main page with "Hello World" message
- [ ] Display user info if authenticated
- [ ] Show sample data from Firestore
- [ ] Add basic styling

## 5. Security & Optimization

### Security Rules

- [ ] Update Firestore security rules in `firestore.rules`
- [ ] Update authentication settings if needed
- [ ] Test security rules using Firebase emulator
- [ ] Deploy rules: `firebase deploy --only firestore:rules`

### Performance

- [ ] Implement lazy loading for Firebase imports
- [ ] Add loading states for async operations
- [ ] Implement error handling
- [ ] Optimize bundle size

## 6. Testing

### Local Testing

- [ ] Run development server: `npm run dev`
- [ ] Test all authentication flows
- [ ] Test all database operations
- [ ] Check responsive design
- [ ] Test error scenarios

### Firebase Emulator (Optional)

- [ ] Install emulator: `firebase init emulators`
- [ ] Start emulator: `firebase emulators:start`
- [ ] Test with emulator data

## 7. Build & Deploy

### Build Process

- [ ] Update `next.config.js` for static export (if using Firebase Hosting):
  ```javascript
  module.exports = {
    output: "export",
  };
  ```
- [ ] Build application: `npm run build`
- [ ] Test production build locally: `npm run start`

## Common Issues & Solutions

- [ ] **CORS errors**: Check Firebase project settings and allowed domains
- [ ] **Authentication persistence**: Ensure auth state is properly managed
- [ ] **Build failures**: Check environment variables and Next.js config
- [ ] **Deployment issues**: Verify Firebase CLI is logged in and project is selected
- [ ] **Performance issues**: Review Firebase usage and implement caching

## Resources

- [Next.js Documentation](https://nextjs.org/docs)
- [Firebase Documentation](https://firebase.google.com/docs)
- [Firebase CLI Reference](https://firebase.google.com/docs/cli)
- [Next.js Deployment Guide](https://nextjs.org/docs/deployment)
