'use client';

import dynamic from 'next/dynamic';
import ChartErrorBoundary from './ChartErrorBoundary';

const MarketPriceChart = dynamic(
  () => import('./MarketPriceChart').catch(err => {
    console.error('Failed to load MarketPriceChart:', err);
    return { default: () => <div className="flex items-center justify-center h-[400px] bg-gray-800 rounded-lg text-red-500">Failed to load chart</div> };
  }),
  { 
    ssr: false,
    loading: () => (
      <div className="flex items-center justify-center h-[400px] bg-gray-800 rounded-lg">
        <div className="text-gray-400">Loading chart...</div>
      </div>
    )
  }
);

export default function MarketPriceChartWrapper(props: any) {
  return (
    <ChartErrorBoundary>
      <MarketPriceChart {...props} />
    </ChartErrorBoundary>
  );
}