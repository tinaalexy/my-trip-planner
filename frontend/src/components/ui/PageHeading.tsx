import type { ReactNode } from 'react'

export default function PageHeading({ children }: { children: ReactNode }) {
  return <h1 className="text-2xl font-bold text-gray-900 mb-6">{children}</h1>
}
