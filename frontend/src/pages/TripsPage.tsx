import { Link } from 'react-router-dom'
import AppShell from '../components/AppShell'
import TripCard from '../components/trips/TripCard'
import Spinner from '../components/ui/Spinner'
import ErrorBanner from '../components/ui/ErrorBanner'
import Button from '../components/ui/Button'
import { useTrips } from '../hooks/useTrips'

export default function TripsPage() {
  const { data: trips, isLoading, error } = useTrips()
  const apiError = error ? 'Failed to load trips. Please try again.' : null

  return (
    <AppShell>
      <div className="flex items-center justify-between mb-6">
        <h1 className="text-2xl font-bold text-gray-900">My Trips</h1>
        <Link to="/trips/new">
          <Button>+ New Trip</Button>
        </Link>
      </div>
      <ErrorBanner message={apiError} />
      {isLoading && <Spinner />}
      {!isLoading && trips?.length === 0 && (
        <div className="text-center py-20">
          <div className="text-5xl mb-4">✈️</div>
          <p className="text-gray-500 text-lg mb-4">No trips yet</p>
          <Link to="/trips/new">
            <Button>Create your first trip</Button>
          </Link>
        </div>
      )}
      {!isLoading && trips && trips.length > 0 && (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {trips.map(trip => <TripCard key={trip.id} trip={trip} />)}
        </div>
      )}
    </AppShell>
  )
}
