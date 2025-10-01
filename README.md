# 🔥 Firebase Authentication Template

A production-ready Next.js template with Firebase Authentication featuring Google OAuth integration, modern UI components, and TypeScript support.

## ✨ Features

- 🔥 **Firebase Authentication** - Complete auth system setup
- 🔑 **Email/Password Auth** - Traditional login and registration
- 🚀 **Google OAuth** - One-click Google sign-in
- 🗄️ **Firestore Ready** - Database integration prepared
- 🎨 **Modern UI** - Clean design with Tailwind CSS
- 📱 **Responsive Design** - Mobile-first approach
- 🌙 **Dark Mode Support** - Automatic theme switching
- ⚡ **Next.js 15** - Latest Next.js with App Router
- 🔒 **TypeScript** - Full type safety

## Quick Start

### 1. Clone and Install

```bash
git clone <repository-url>
cd firebase-template
npm install
```

### 2. Firebase Setup

1. Create a new project at [Firebase Console](https://console.firebase.google.com/)
2. Enable Authentication:
   - Go to **Authentication** > **Sign-in method**
   - Enable **Email/Password** provider
   - Enable **Google** provider and configure OAuth consent screen
3. Get your Firebase config:
   - Go to **Project Settings** > **General** > **Your apps**
   - Copy the Firebase configuration object

### 3. Environment Setup

```bash
cp .env.example .env.local
```

Edit `.env.local` with your Firebase credentials:

```env
NEXT_PUBLIC_FIREBASE_API_KEY=your_api_key_here
NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=your_project_id.firebaseapp.com
NEXT_PUBLIC_FIREBASE_PROJECT_ID=your_project_id
NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET=your_project_id.appspot.com
NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID=your_sender_id
NEXT_PUBLIC_FIREBASE_APP_ID=your_app_id
```

### 4. Run Development Server

```bash
npm run dev
```

Open [http://localhost:3000](http://localhost:3000) to see your app.

## Development

## 📁 Project Structure

```
src/
├── app/
│   ├── layout.tsx              # Root layout with AuthProvider
│   └── page.tsx                # Home page with auth demo
├── components/
│   ├── FirestoreDemo.tsx       # Firestore integration example
│   ├── LoginForm.tsx           # Login/Register form with Google OAuth
│   └── UserProfile.tsx         # User profile display component
├── context/
│   └── AuthContext.tsx         # Authentication context provider
└── lib/
    └── firebase.ts             # Firebase configuration and setup
```

## 🔧 Available Scripts

```bash
npm run dev          # Start development server
npm run build        # Build for production
npm run start        # Start production server
npm run lint         # Run ESLint
```

## 🎯 Authentication Features

### Email/Password Authentication
- User registration with email validation
- Secure login with error handling
- Form validation and user feedback

### Google OAuth Integration
- One-click Google sign-in
- Automatic user profile creation
- Seamless authentication flow
- Error handling for OAuth failures

### User Management
- Persistent authentication state
- User profile display
- Secure logout functionality
- Loading states during auth operations

## 🚀 Deployment

### Vercel (Recommended)

1. Push your code to GitHub
2. Connect your repository to [Vercel](https://vercel.com)
3. Add environment variables in Vercel dashboard
4. Deploy automatically on every push

### Other Platforms

This template works with any platform that supports Next.js:
- Netlify
- Railway
- Digital Ocean
- AWS Amplify

## 🔒 Security Best Practices

- Environment variables for sensitive data
- Client-side auth state management
- Proper error handling without exposing sensitive info
- TypeScript for compile-time safety
- Firebase security rules ready for implementation

## 🎨 UI Components

### LoginForm Component
- Responsive design with mobile optimization
- Toggle between login and registration modes
- Google OAuth button with official branding
- Real-time form validation
- Dark mode support

### UserProfile Component
- Display authenticated user information
- Logout functionality
- Profile picture from Google OAuth
- Clean, accessible design

## 🔧 Customization

### Adding New Auth Providers

1. Enable the provider in Firebase Console
2. Import the provider in `src/lib/firebase.ts`
3. Add the sign-in method to `AuthContext.tsx`
4. Update the `LoginForm.tsx` component

### Styling

The template uses Tailwind CSS with a custom configuration. Modify:
- `tailwind.config.js` for theme customization
- `src/app/globals.css` for global styles
- Individual components for specific styling

### Database Integration

Ready for Firestore integration:
- Firebase config already includes Firestore
- Example component in `FirestoreDemo.tsx`
- Add your database rules in Firebase Console

## 🆘 Troubleshooting

### Common Issues

- **White page**: Check environment variables in `.env.local`
- **Google OAuth not working**: Verify authorized domains in Firebase Console
- **Build errors**: Run `npm run build` to check for TypeScript errors

## 📝 License

This template is open source and available under the [MIT License](LICENSE).

## 🤝 Contributing

Contributions, issues, and feature requests are welcome!

---

**Happy coding!** 🎉