import { Tooltip } from "@radix-ui/themes";

type VerifiedIconProps = {
  className?: string;
  size?: number;
};

export const VerifiedIcon = ({
  className = "",
  size = 18,
}: VerifiedIconProps) => {
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
              "0 4px 12px rgba(0, 0, 0, 0.2), 0 0 2px rgba(34, 197, 94, 0.2)",
            padding: "10px 12px",
            borderRadius: "8px",
            outline: "none",
          }}
        >
          <div className="flex items-center gap-2 mb-1">
            <span className="text-green-400 font-semibold">Verified DAO</span>
            <div className="h-1.5 w-1.5 rounded-full bg-green-500 animate-pulse"></div>
          </div>
          <p>
            This DAO has been verified by our team and is safe to interact with.
          </p>
        </div>
      }
      style={{
        outline: "none",
      }}
    >
      <div className={`inline-flex items-center justify-center ${className}`}>
        <svg
          width={size}
          height={size}
          viewBox="0 0 24 24"
          fill="none"
          xmlns="http://www.w3.org/2000/svg"
          className="text-green-500"
        >
          <path
            d="M13.8179 4.54512L13.6275 4.27845C12.8298 3.16176 11.1702 3.16176 10.3725 4.27845L10.1821 4.54512C9.76092 5.13471 9.05384 5.45043 8.33373 5.37041L7.48471 5.27608C6.21088 5.13454 5.13454 6.21088 5.27608 7.48471L5.37041 8.33373C5.45043 9.05384 5.13471 9.76092 4.54512 10.1821L4.27845 10.3725C3.16176 11.1702 3.16176 12.8298 4.27845 13.6275L4.54512 13.8179C5.13471 14.2391 5.45043 14.9462 5.37041 15.6663L5.27608 16.5153C5.13454 17.7891 6.21088 18.8655 7.48471 18.7239L8.33373 18.6296C9.05384 18.5496 9.76092 18.8653 10.1821 19.4549L10.3725 19.7215C11.1702 20.8382 12.8298 20.8382 13.6275 19.7215L13.8179 19.4549C14.2391 18.8653 14.9462 18.5496 15.6663 18.6296L16.5153 18.7239C17.7891 18.8655 18.8655 17.7891 18.7239 16.5153L18.6296 15.6663C18.5496 14.9462 18.8653 14.2391 19.4549 13.8179L19.7215 13.6275C20.8382 12.8298 20.8382 11.1702 19.7215 10.3725L19.4549 10.1821C18.8653 9.76092 18.5496 9.05384 18.6296 8.33373L18.7239 7.48471C18.8655 6.21088 17.7891 5.13454 16.5153 5.27608L15.6663 5.37041C14.9462 5.45043 14.2391 5.13471 13.8179 4.54512Z"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
          <path
            d="M9 12L10.8189 13.8189V13.8189C10.9189 13.9189 11.0811 13.9189 11.1811 13.8189V13.8189L15 10"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </div>
    </Tooltip>
  );
};

export default VerifiedIcon;
