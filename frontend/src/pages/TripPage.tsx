import { useParams } from 'react-router-dom'
import AppShell from '../components/AppShell'
import ItineraryView from '../components/itinerary/ItineraryView'
import Spinner from '../components/ui/Spinner'
import ErrorBanner from '../components/ui/ErrorBanner'
import { useTripDetail } from '../hooks/useTripDetail'

export default function TripPage() {
  const { tripId } = useParams<{ tripId: string }>()
  const { data: trip, isLoading, error } = useTripDetail(tripId!)
  const apiError = error ? 'Failed to load trip. Please try again.' : null

  return (
    <AppShell>
      <ErrorBanner message={apiError} />
      {isLoading && <Spinner />}
      {trip && <ItineraryView trip={trip} />}
    </AppShell>
  )
}
