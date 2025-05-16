import { Tooltip } from "@radix-ui/themes";

type UnverifiedIconProps = {
  className?: string;
  size?: number;
};

export const UnverifiedIcon = ({
  className = "",
  size = 18,
}: UnverifiedIconProps) => {
  const glow = size > 24 ? "url(#softGlow)" : undefined;

  return (
    <Tooltip
      content={
        <div
          className="text-sm text-gray-100 max-w-xs backdrop-blur-sm"
          style={{
            background:
              "linear-gradient(145deg, rgba(31, 41, 55, 0.9), rgba(31, 41, 55, 0.8))",
            border: "1px solid rgba(55, 65, 81, 0.6)",
            boxShadow:
              "0 4px 12px rgba(0, 0, 0, 0.2), 0 0 2px rgba(245, 158, 11, 0.2)",
            padding: "10px 12px",
            borderRadius: "8px",
          }}
        >
          <div className="flex items-center gap-2 mb-1">
            <span className="text-amber-400 font-semibold">Unverified DAO</span>
            <div className="h-1.5 w-1.5 rounded-full bg-amber-500 animate-pulse" />
          </div>
          <p>
            Anyone can create a DAO, so exercise caution when interacting with
            unverified sources.
          </p>
        </div>
      }
    >
      <div className={`inline-flex items-center justify-center ${className}`}>
        <svg
          width={size}
          height={size}
          viewBox="0 0 24 24"
          xmlns="http://www.w3.org/2000/svg"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <defs>
            <filter id="softGlow" x="-50%" y="-50%" width="200%" height="200%">
              <feDropShadow
                dx="0"
                dy="0"
                stdDeviation="1.5"
                floodColor="#f59e0b"
                floodOpacity="0.5"
              />
              <feDropShadow
                dx="0"
                dy="0"
                stdDeviation="3"
                floodColor="#f59e0b"
                floodOpacity="0.2"
              />
            </filter>
          </defs>

          {/* Background fill for the triangle */}
          <path
            d="M10.363 3.591l-8.106 13.534a1.914 1.914 0 0 0 1.636 2.871h16.214a1.914 1.914 0 0 0 1.636 -2.87l-8.106 -13.536a1.914 1.914 0 0 0 -3.274 0z"
            fill="rgba(245, 158, 11, 0.08)"
            stroke="#f59e0b"
            strokeWidth="2"
            filter={glow}
          />

          {/* Exclamation mark - vertical line */}
          <path
            d="M12 9v4"
            stroke="#f59e0b"
            strokeWidth="2"
            strokeLinecap="round"
          />

          {/* Exclamation mark - dot */}
          <path
            d="M12 16h.01"
            stroke="#f59e0b"
            strokeWidth="2"
            strokeLinecap="round"
          />
        </svg>
      </div>
    </Tooltip>
  );
};

export default UnverifiedIcon;
