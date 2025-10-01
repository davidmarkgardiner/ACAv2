'use client'

import { useAuth } from '@/context/AuthContext'

export default function UserProfile() {
  const { user, logout } = useAuth()

  if (!user) return null

  return (
    <div className="max-w-md mx-auto mt-8 p-6 bg-white rounded-lg shadow-md dark:bg-gray-800">
      <h2 className="text-2xl font-bold mb-4">Welcome!</h2>

      <div className="space-y-2 mb-6">
        <p><span className="font-medium">Email:</span> {user.email}</p>
        <p><span className="font-medium">User ID:</span> {user.uid}</p>
        <p><span className="font-medium">Verified:</span> {user.emailVerified ? 'Yes' : 'No'}</p>
      </div>

      <button
        onClick={logout}
        className="w-full py-2 px-4 bg-red-600 text-white rounded-md hover:bg-red-700 focus:outline-none focus:ring-2 focus:ring-red-500"
      >
        Logout
      </button>
    </div>
  )
}