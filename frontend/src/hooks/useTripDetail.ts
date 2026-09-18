import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import api from '../lib/axios'
import type { TripDetail } from '../types'

export function useTripDetail(tripId: string) {
  return useQuery<TripDetail>({
    queryKey: ['trips', tripId],
    queryFn: () => api.get(`/trips/${tripId}`).then(r => r.data),
  })
}

export function useAddActivity(tripId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (data: { dayIndex: number; text: string }) =>
      api.post(`/trips/${tripId}/activities`, data).then(r => r.data),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['trips', tripId] }),
  })
}

export function useUpdateActivity(tripId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ activityId, text }: { activityId: string; text: string }) =>
      api.put(`/trips/${tripId}/activities/${activityId}`, { text }).then(r => r.data),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['trips', tripId] }),
  })
}

export function useDeleteActivity(tripId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (activityId: string) =>
      api.delete(`/trips/${tripId}/activities/${activityId}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['trips', tripId] }),
  })
}
