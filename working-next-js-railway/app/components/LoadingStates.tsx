export function ProposalSkeleton() {
  return (
    <div className="flex flex-col flex-1 animate-pulse">
      {/* Header skeleton */}
      <div className="pr-6 pl-7 mt-4">
        <div className="h-8 bg-gray-800 rounded w-3/4 mb-4"></div>
        <div className="flex items-center gap-4 mb-4">
          <div className="h-5 bg-gray-800 rounded w-24"></div>
          <div className="h-5 bg-gray-800 rounded w-32"></div>
        </div>
      </div>

      {/* Chart area skeleton */}
      <div className="px-7 py-4">
        <div className="h-[400px] bg-gray-800 rounded-lg"></div>
      </div>

      {/* Trade form skeleton */}
      <div className="px-7 py-4">
        <div className="h-96 bg-gray-800 rounded-lg"></div>
      </div>
    </div>
  );
}

export function DaoSkeleton() {
  return (
    <div className="p-6 max-w-6xl mx-auto animate-pulse">
      {/* Header with background */}
      <div className="relative mb-24">
        <div className="h-48 w-full absolute -z-20 -top-32 rounded-xl bg-gray-800"></div>
        <div className="flex items-end flex-wrap">
          <div className="w-32 h-32 bg-gray-700 rounded-full mr-4"></div>
          <div>
            <div className="h-8 bg-gray-800 rounded w-48 mb-2"></div>
            <div className="h-4 bg-gray-800 rounded w-64"></div>
          </div>
        </div>
      </div>

      {/* Stats cards */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-8">
        <div className="h-24 bg-gray-800 rounded-lg"></div>
        <div className="h-24 bg-gray-800 rounded-lg"></div>
        <div className="h-24 bg-gray-800 rounded-lg"></div>
      </div>

      {/* Proposals section */}
      <div className="space-y-4">
        <div className="h-6 bg-gray-800 rounded w-32 mb-4"></div>
        <div className="h-48 bg-gray-800 rounded-lg"></div>
        <div className="h-48 bg-gray-800 rounded-lg"></div>
      </div>
    </div>
  );
}

export function TradeDashboardSkeleton() {
  return (
    <div className="w-full mx-auto p-6 animate-pulse">
      <div className="space-y-4">
        {/* Title */}
        <div className="h-8 bg-gray-800 rounded w-1/3 mb-6"></div>
        
        {/* Cards grid */}
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {[...Array(6)].map((_, i) => (
            <div key={i} className="h-64 bg-gray-800 rounded-lg"></div>
          ))}
        </div>
      </div>
    </div>
  );
}