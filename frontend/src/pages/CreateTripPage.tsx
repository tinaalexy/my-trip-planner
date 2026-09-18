import AppShell from '../components/AppShell'
import PageHeading from '../components/ui/PageHeading'
import TripForm from '../components/trips/TripForm'

export default function CreateTripPage() {
  return (
    <AppShell>
      <PageHeading>Create a New Trip</PageHeading>
      <TripForm />
    </AppShell>
  )
}
