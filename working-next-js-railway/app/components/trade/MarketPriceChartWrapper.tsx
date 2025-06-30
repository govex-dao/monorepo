'use client';

import dynamic from 'next/dynamic';

const MarketPriceChart = dynamic(
  () => import('./MarketPriceChart'),
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
  return <MarketPriceChart {...props} />;
}