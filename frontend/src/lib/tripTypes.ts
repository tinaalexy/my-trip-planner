export const TRIP_TYPE_OPTIONS = [
  { label: 'Solo',             value: 'solo' },
  { label: 'Couple',           value: 'couple' },
  { label: 'Family',           value: 'family' },
  { label: 'Group of Friends', value: 'group_of_friends' },
] as const

export type TripTypeValue = typeof TRIP_TYPE_OPTIONS[number]['value']

export function tripTypeLabel(value: string): string {
  return TRIP_TYPE_OPTIONS.find(o => o.value === value)?.label ?? value
}
