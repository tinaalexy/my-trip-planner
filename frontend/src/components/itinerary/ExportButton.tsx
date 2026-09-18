import { useState } from 'react'
import html2canvas from 'html2canvas'
import jsPDF from 'jspdf'
import Button from '../ui/Button'
import type { Trip } from '../../types'

export default function ExportButton({ trip }: { trip: Trip }) {
  const [loading, setLoading] = useState(false)

  async function handleExport() {
    const el = document.getElementById('itinerary-print-area')
    if (!el) return
    setLoading(true)
    try {
      const canvas = await html2canvas(el, { scale: 2, useCORS: true })
      const imgData = canvas.toDataURL('image/png')
      const pdf = new jsPDF({
        orientation: 'portrait',
        unit: 'px',
        format: [canvas.width / 2, canvas.height / 2],
      })
      pdf.addImage(imgData, 'PNG', 0, 0, canvas.width / 2, canvas.height / 2)
      const dest = trip.destination.replace(/\s+/g, '-').replace(/[^a-zA-Z0-9-]/g, '')
      pdf.save(`itinerary-${trip.startDate}-${dest}.pdf`)
    } finally {
      setLoading(false)
    }
  }

  return (
    <Button
      onClick={handleExport}
      loading={loading}
      className="bg-green-600 hover:bg-green-700 text-white mb-6"
    >
      Export PDF
    </Button>
  )
}
