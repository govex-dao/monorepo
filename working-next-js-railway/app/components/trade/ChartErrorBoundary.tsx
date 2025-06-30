'use client';

import React from 'react';

interface Props {
  children: React.ReactNode;
  fallback?: React.ReactNode;
}

interface State {
  hasError: boolean;
  error?: Error;
}

class ChartErrorBoundary extends React.Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { hasError: false };
  }

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, errorInfo: React.ErrorInfo) {
    // Log to error reporting service in production
    if (process.env.NODE_ENV === 'development') {
      console.error('Chart error:', error, errorInfo);
    }
  }

  render() {
    if (this.state.hasError) {
      return (
        this.props.fallback || (
          <div className="flex items-center justify-center h-[400px] bg-gray-800 rounded-lg">
            <div className="text-center">
              <p className="text-red-400 mb-2">Unable to load chart</p>
              <p className="text-gray-400 text-sm">
                {this.state.error?.message || 'An error occurred'}
              </p>
            </div>
          </div>
        )
      );
    }

    return this.props.children;
  }
}

export default ChartErrorBoundary;