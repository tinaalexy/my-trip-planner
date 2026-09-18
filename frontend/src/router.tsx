import { createBrowserRouter, Navigate } from 'react-router-dom'
import { useAuth } from './contexts/AuthContext'
import ProtectedRoute from './components/ProtectedRoute'
import LoginPage from './pages/LoginPage'
import SignupPage from './pages/SignupPage'
import TripsPage from './pages/TripsPage'
import CreateTripPage from './pages/CreateTripPage'
import TripPage from './pages/TripPage'

function RootRedirect() {
  const { user } = useAuth()
  return <Navigate to={user ? '/trips' : '/login'} replace />
}

export const router = createBrowserRouter([
  { path: '/', element: <RootRedirect /> },
  { path: '/login', element: <LoginPage /> },
  { path: '/signup', element: <SignupPage /> },
  {
    element: <ProtectedRoute />,
    children: [
      { path: '/trips', element: <TripsPage /> },
      { path: '/trips/new', element: <CreateTripPage /> },
      { path: '/trips/:tripId', element: <TripPage /> },
    ],
  },
])
