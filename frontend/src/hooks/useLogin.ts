import { useMutation } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import api from '../lib/axios'
import { useAuth } from '../contexts/AuthContext'

export function useLogin() {
  const { login } = useAuth()
  const navigate = useNavigate()
  return useMutation({
    mutationFn: (data: { username: string; password: string }) =>
      api.post('/auth/login', data).then(r => r.data),
    onSuccess: (data) => {
      login(data.token, data.user)
      navigate('/trips')
    },
  })
}
