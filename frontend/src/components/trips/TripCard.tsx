import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { tripTypeLabel } from '../../lib/tripTypes'
import { useDeleteTrip } from '../../hooks/useTrips'
import Button from '../ui/Button'
import type { Trip } from '../../types'

function formatDateRange(start: string, end: string) {
  const fmt = new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'long', year: 'numeric' })
  return `${fmt.format(new Date(start + 'T00:00:00'))} – ${fmt.format(new Date(end + 'T00:00:00'))}`
}

export default function TripCard({ trip }: { trip: Trip }) {
  const navigate = useNavigate()
  const [confirming, setConfirming] = useState(false)
  const { mutate: deleteTrip, isPending } = useDeleteTrip()

  return (
    <div
      className="bg-white border border-gray-200 rounded-lg p-4 cursor-pointer hover:shadow-md transition-shadow"
      onClick={() => !confirming && navigate(`/trips/${trip.id}`)}
    >
      <h3 className="font-bold text-lg text-gray-900 mb-1">{trip.destination}</h3>
      <p className="text-sm text-gray-500 mb-2">{formatDateRange(trip.startDate, trip.endDate)}</p>
      <div className="flex items-center justify-between">
        <span className="text-xs font-semibold bg-blue-50 text-blue-700 border border-blue-200 rounded-full px-3 py-1">
          {tripTypeLabel(trip.tripType)}
        </span>
        {!confirming ? (
          <button
            onClick={e => { e.stopPropagation(); setConfirming(true) }}
            className="text-xs text-red-600 hover:underline"
          >
            Delete
          </button>
        ) : (
          <div className="flex items-center gap-2" onClick={e => e.stopPropagation()}>
            <span className="text-xs text-gray-600">Are you sure?</span>
            <Button variant="danger" loading={isPending} className="text-xs px-2 py-1"
              onClick={() => deleteTrip(trip.id)}>
              Confirm
            </Button>
            <Button variant="secondary" className="text-xs px-2 py-1"
              onClick={() => setConfirming(false)}>
              Cancel
            </Button>
          </div>
        )}
      </div>
    </div>
  )
}
