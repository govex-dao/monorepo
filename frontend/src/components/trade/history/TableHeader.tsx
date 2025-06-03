export type SortField = "time" | "amount" | "price" | "impact";
export type SortDirection = "ascending" | "descending";

export interface SortConfig {
  field: SortField;
  direction: SortDirection;
}

const getSortIndicator = (field: SortField, config: SortConfig) => {
  const isActive = config.field === field;
  return (
    <span
      className={`transition-colors ${isActive ? "text-gray-200" : "text-gray-600 hover:text-gray-200"}`}
      aria-hidden="true"
    >
      {isActive ? (config.direction === "descending" ? "↓" : "↑") : "↓"}
    </span>
  );
};

export function TableHeader({
  onSort,
  sortConfig,
}: {
  onSort: (field: SortField) => void;
  sortConfig: SortConfig;
}) {
  return (
    <thead className="select-none">
      <tr className="text-xs text-gray-400 border-b border-gray-800 bg-gray-900/70">
        <th
          className="text-left py-3.5 px-4 font-medium cursor-pointer hover:text-gray-300 transition-colors"
          onClick={() => onSort("time")}
          role="columnheader"
          aria-sort={
            sortConfig.field === "time" ? sortConfig.direction : undefined
          }
        >
          <div className="flex items-center gap-1.5">
            Time
            {getSortIndicator("time", sortConfig)}
          </div>
        </th>
        <th className="text-left py-3.5 px-4 font-medium" role="columnheader">
          Type
        </th>
        <th className="text-left py-3.5 px-4 font-medium" role="columnheader">
          Outcome
        </th>
        <th
          className="text-right py-3.5 px-4 font-medium cursor-pointer hover:text-gray-300 transition-colors"
          onClick={() => onSort("price")}
          role="columnheader"
          aria-sort={
            sortConfig.field === "price" ? sortConfig.direction : undefined
          }
        >
          <div className="flex items-center justify-end gap-1.5">
            Price
            {getSortIndicator("price", sortConfig)}
          </div>
        </th>
        <th
          className="text-right py-3.5 px-4 font-medium cursor-pointer hover:text-gray-300 transition-colors"
          onClick={() => onSort("amount")}
          role="columnheader"
          aria-sort={
            sortConfig.field === "amount" ? sortConfig.direction : undefined
          }
        >
          <div className="flex items-center justify-end gap-1.5">
            Amount
            {getSortIndicator("amount", sortConfig)}
          </div>
        </th>
        <th
          className="text-right py-3.5 px-4 font-medium cursor-pointer hover:text-gray-300 transition-colors"
          onClick={() => onSort("impact")}
          role="columnheader"
          aria-sort={
            sortConfig.field === "impact" ? sortConfig.direction : undefined
          }
        >
          <div className="flex items-center justify-end gap-1.5">
            Impact
            {getSortIndicator("impact", sortConfig)}
          </div>
        </th>
        <th className="text-left py-3.5 px-4 font-medium" role="columnheader">
          Trader
        </th>
      </tr>
    </thead>
  );
}
