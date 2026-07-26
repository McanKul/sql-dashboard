import { Component, type ErrorInfo, type ReactNode } from 'react'

interface ExplainPlanErrorBoundaryProps {
  children: ReactNode
  fallback: ReactNode
  resetKey?: string
  onError?: (error: Error, info: ErrorInfo) => void
}

interface ExplainPlanErrorBoundaryState {
  failed: boolean
}

/** Keeps an optional visualization failure from taking down query details. */
export class ExplainPlanErrorBoundary extends Component<ExplainPlanErrorBoundaryProps, ExplainPlanErrorBoundaryState> {
  state: ExplainPlanErrorBoundaryState = { failed: false }

  static getDerivedStateFromError(): ExplainPlanErrorBoundaryState {
    return { failed: true }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    this.props.onError?.(error, info)
  }

  componentDidUpdate(previousProps: ExplainPlanErrorBoundaryProps) {
    if (this.state.failed && previousProps.resetKey !== this.props.resetKey) {
      this.setState({ failed: false })
    }
  }

  render() {
    return this.state.failed ? this.props.fallback : this.props.children
  }
}
