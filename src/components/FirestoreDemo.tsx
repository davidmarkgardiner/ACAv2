'use client'

import { useState, useEffect } from 'react'
import { collection, addDoc, getDocs, query, orderBy, deleteDoc, doc } from 'firebase/firestore'
import { db } from '@/lib/firebase'
import { useAuth } from '@/context/AuthContext'

interface Message {
  id: string
  text: string
  timestamp: any
  userId: string
  userEmail: string
}

export default function FirestoreDemo() {
  const [messages, setMessages] = useState<Message[]>([])
  const [newMessage, setNewMessage] = useState('')
  const [loading, setLoading] = useState(false)
  const { user } = useAuth()

  const fetchMessages = async () => {
    try {
      const q = query(collection(db, 'messages'), orderBy('timestamp', 'desc'))
      const querySnapshot = await getDocs(q)
      const messageList: Message[] = []

      querySnapshot.forEach((doc) => {
        messageList.push({
          id: doc.id,
          ...doc.data()
        } as Message)
      })

      setMessages(messageList)
    } catch (error) {
      console.error('Error fetching messages:', error)
    }
  }

  const addMessage = async (e: React.FormEvent) => {
    e.preventDefault()

    if (!newMessage.trim() || !user) return

    try {
      setLoading(true)
      await addDoc(collection(db, 'messages'), {
        text: newMessage,
        timestamp: new Date(),
        userId: user.uid,
        userEmail: user.email
      })

      setNewMessage('')
      await fetchMessages()
    } catch (error) {
      console.error('Error adding message:', error)
    } finally {
      setLoading(false)
    }
  }

  const deleteMessage = async (messageId: string) => {
    try {
      await deleteDoc(doc(db, 'messages', messageId))
      await fetchMessages()
    } catch (error) {
      console.error('Error deleting message:', error)
    }
  }

  useEffect(() => {
    fetchMessages()
  }, [])

  if (!user) {
    return (
      <div className="max-w-2xl mx-auto mt-8 p-6 bg-white rounded-lg shadow-md dark:bg-gray-800">
        <h3 className="text-xl font-bold mb-4">Firestore Demo</h3>
        <p className="text-gray-600">Please login to use the messaging feature.</p>
      </div>
    )
  }

  return (
    <div className="max-w-2xl mx-auto mt-8 p-6 bg-white rounded-lg shadow-md dark:bg-gray-800">
      <h3 className="text-xl font-bold mb-4">Firestore Demo - Messages</h3>

      <form onSubmit={addMessage} className="mb-6">
        <div className="flex gap-2">
          <input
            type="text"
            value={newMessage}
            onChange={(e) => setNewMessage(e.target.value)}
            placeholder="Enter a message..."
            className="flex-1 px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:border-gray-600"
          />
          <button
            type="submit"
            disabled={loading}
            className="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:opacity-50"
          >
            {loading ? 'Adding...' : 'Add'}
          </button>
        </div>
      </form>

      <div className="space-y-3">
        {messages.length === 0 ? (
          <p className="text-gray-500 text-center py-8">No messages yet. Add the first one!</p>
        ) : (
          messages.map((message) => (
            <div key={message.id} className="p-3 border border-gray-200 rounded-md dark:border-gray-600">
              <div className="flex justify-between items-start">
                <div className="flex-1">
                  <p className="text-sm text-gray-600 dark:text-gray-400">
                    {message.userEmail} • {message.timestamp?.toDate?.()?.toLocaleDateString() || 'Unknown date'}
                  </p>
                  <p className="mt-1">{message.text}</p>
                </div>
                {user.uid === message.userId && (
                  <button
                    onClick={() => deleteMessage(message.id)}
                    className="ml-2 px-2 py-1 text-xs bg-red-600 text-white rounded hover:bg-red-700"
                  >
                    Delete
                  </button>
                )}
              </div>
            </div>
          ))
        )}
      </div>

      <button
        onClick={fetchMessages}
        className="mt-4 px-4 py-2 bg-gray-600 text-white rounded-md hover:bg-gray-700 focus:outline-none focus:ring-2 focus:ring-gray-500"
      >
        Refresh Messages
      </button>
    </div>
  )
}