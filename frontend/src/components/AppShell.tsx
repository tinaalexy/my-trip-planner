import { Link } from 'react-router-dom'
import { useAuth } from '../contexts/AuthContext'
import type { ReactNode } from 'react'

export default function AppShell({ children }: { children: ReactNode }) {
  const { user, logout } = useAuth()

  return (
    <div className="min-h-screen bg-gray-50">
      <nav className="bg-white border-b border-gray-200 px-6 py-3 flex items-center justify-between">
        <span className="font-bold text-lg text-gray-900">My Trip Planner</span>
        <div className="flex items-center gap-4">
          <Link to="/trips" className="text-sm text-blue-600 hover:underline">My Trips</Link>
          <span className="text-sm text-gray-500">{user?.username}</span>
          <button
            onClick={logout}
            className="text-sm bg-gray-100 hover:bg-gray-200 border border-gray-300 rounded px-3 py-1"
          >
            Logout
          </button>
        </div>
      </nav>
      <main className="px-6 py-8 max-w-4xl mx-auto">
        {children}
      </main>
    </div>
  )
}
