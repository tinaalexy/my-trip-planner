import { useState } from 'react'
import { useUpdateActivity, useDeleteActivity } from '../../hooks/useTripDetail'
import Button from '../ui/Button'
import type { Activity } from '../../types'

interface Props {
  tripId: string
  activity: Activity
}

export default function ActivityItem({ tripId, activity }: Props) {
  const [editing, setEditing] = useState(false)
  const [editText, setEditText] = useState(activity.text)
  const [editError, setEditError] = useState<string | null>(null)
  const [confirming, setConfirming] = useState(false)
  const { mutate: updateActivity, isPending: saving } = useUpdateActivity(tripId)
  const { mutate: deleteActivity, isPending: deleting } = useDeleteActivity(tripId)

  function handleSave() {
    const trimmed = editText.trim()
    if (!trimmed) { setEditError('Required'); return }
    if (trimmed.length > 300) { setEditError('Max 300 characters'); return }
    setEditError(null)
    updateActivity(
      { activityId: activity.id, text: trimmed },
      {
        onSuccess: () => setEditing(false),
        onError: (err: any) => {
          setEditError(err.response?.data?.detail?.message ?? 'Failed to save. Please try again.')
        }
      }
    )
  }

  function handleCancel() {
    setEditing(false)
    setEditText(activity.text)
    setEditError(null)
  }

  if (editing) {
    return (
      <div className="py-2 border-b border-gray-100">
        <input
          value={editText}
          onChange={e => setEditText(e.target.value)}
          className={`w-full border rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 mb-1 ${editError ? 'border-red-500' : 'border-gray-300'}`}
          autoFocus
        />
        {editError && <p className="text-xs text-red-600 mb-1">{editError}</p>}
        <div className="flex gap-2">
          <Button onClick={handleSave} loading={saving} type="button" className="text-xs px-3 py-1">Save</Button>
          <Button onClick={handleCancel} variant="secondary" type="button" className="text-xs px-3 py-1">Cancel</Button>
        </div>
      </div>
    )
  }

  return (
    <div className="flex items-center justify-between py-2 border-b border-gray-100 last:border-0">
      <span className="text-sm text-gray-700">{activity.text}</span>
      {!confirming ? (
        <div className="flex items-center gap-2 ml-4 shrink-0">
          <button onClick={() => { setEditing(true); setEditText(activity.text) }}
            className="text-xs text-blue-600 hover:underline">Edit</button>
          <button onClick={() => setConfirming(true)}
            className="text-xs text-red-600 hover:underline">Delete</button>
        </div>
      ) : (
        <div className="flex items-center gap-2 ml-4 shrink-0">
          <span className="text-xs text-gray-600">Sure?</span>
          <Button variant="danger" loading={deleting} className="text-xs px-2 py-1" type="button"
            onClick={() => deleteActivity(activity.id)}>Yes</Button>
          <Button variant="secondary" className="text-xs px-2 py-1" type="button"
            onClick={() => setConfirming(false)}>No</Button>
        </div>
      )}
    </div>
  )
}
