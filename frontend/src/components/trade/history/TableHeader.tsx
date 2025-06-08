export type SortField = "time" | "amount" | "price" | "impact";
export type SortDirection = "ascending" | "descending";

export interface SortConfig {
  field: SortField;
  direction: SortDirection;
}

const getSortIndicator = (field: SortField, config: SortConfig) => {
  const isActive = config.field === field;
  const symbol = isActive && config.direction === "ascending" ? "↑" : "↓";

  return (
    <span
      className={
        isActive ? "text-gray-200" : "text-gray-600 hover:text-gray-200"
      }
      aria-hidden="true"
    >
      {symbol}
    </span>
  );
};

type TableHeaderProps = {
  onSort: (field: SortField) => void;
  sortConfig: SortConfig;
};

export function TableHeader(props: TableHeaderProps) {
  const { onSort, sortConfig } = props;

  const SortableHeader = ({
    field,
    align = "center",
    label,
  }: {
    field: SortField;
    align?: "left" | "right" | "center";
    label?: string;
  }) => (
    <th
      className={`text-${align} py-2.5 sm:py-3.5 px-2 sm:px-4 font-medium cursor-pointer hover:text-gray-300 transition-colors`}
      onClick={() => onSort(field)}
      role="columnheader"
      aria-sort={sortConfig.field === field ? sortConfig.direction : undefined}
    >
      <div
        className={`flex items-center capitalize gap-1.5 ${
          align === "right"
            ? "justify-end"
            : align === "center"
              ? "justify-center"
              : "justify-start"
        }`}
      >
        {label || field}
        {getSortIndicator(field, sortConfig)}
      </div>
    </th>
  );

  const StaticHeader = ({
    field,
    align = "left",
  }: {
    field: string;
    align?: "left" | "right" | "center";
  }) => (
    <th
      className={`text-${align} capitalize py-2.5 sm:py-3.5 px-2 sm:px-4 font-medium`}
      role="columnheader"
    >
      {field}
    </th>
  );

  return (
    <thead className="select-none">
      <tr className="text-xs text-gray-400 border-b border-gray-800 bg-gray-900/70">
        <SortableHeader field="time" align="left" />
        <StaticHeader field="type" />
        <StaticHeader field="outcome" />
        <SortableHeader field="price" align="right" />
        <SortableHeader field="amount" align="right" />
        <SortableHeader field="impact" align="right" label="Reserves impact" />
        <StaticHeader field="trader" align="right" />
      </tr>
    </thead>
  );
}
