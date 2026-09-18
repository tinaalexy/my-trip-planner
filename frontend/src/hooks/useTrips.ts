import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import api from '../lib/axios'
import type { Trip } from '../types'

export function useTrips() {
  return useQuery<Trip[]>({
    queryKey: ['trips'],
    queryFn: () => api.get('/trips').then(r => r.data),
  })
}

export function useCreateTrip() {
  const navigate = useNavigate()
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (data: { destination: string; startDate: string; endDate: string; tripType: string }) =>
      api.post('/trips', data).then(r => r.data),
    onSuccess: (trip: Trip) => {
      qc.invalidateQueries({ queryKey: ['trips'] })
      navigate(`/trips/${trip.id}`)
    },
  })
}

export function useDeleteTrip() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (tripId: string) => api.delete(`/trips/${tripId}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['trips'] }),
  })
}
