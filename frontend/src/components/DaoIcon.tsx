import { Flex } from "@radix-ui/themes";

type DaoIconProps = {
  icon: string | null;
  name: string;
  className?: string;
  size?: "xs" | "sm" | "md" | "lg" | "xl";
};

export function DaoIcon(props: DaoIconProps) {
  const { icon, name, className, size = "md" } = props;

  const sizeClasses = {
    xs: "w-4 h-4",
    sm: "w-6 h-6",
    md: "w-8 h-8",
    lg: "w-12 h-12",
    xl: "w-32 h-32",
  };

  const textSizeClasses = {
    xs: "text-xs",
    sm: "text-sm",
    md: "text-base",
    lg: "text-xl",
    xl: "text-3xl",
  };

  const sizeClass = sizeClasses[size];
  const textSizeClass = textSizeClasses[size];

  return (
    <Flex
      className={`rounded-full ${className} ${sizeClass} items-center justify-center overflow-hidden aspect-square border-gray-500/30 border-2 bg-transparent`}
    >
      {icon ? (
        <img src={icon} alt={name} className="w-full h-full object-cover" />
      ) : (
        <p className={`font-medium ${textSizeClass} bg-[#111113] rounded-full w-full h-full flex items-center justify-center`}>{props.name[0]}</p>
      )}
    </Flex>
  );
}
