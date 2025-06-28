"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ReactNode } from "react";

interface ClientLinkProps {
  href: string;
  children: ReactNode;
  className?: string | ((isActive: boolean) => string);
  onClick?: () => void;
}

export function ClientLink({ href, children, className, onClick }: ClientLinkProps) {
  const pathname = usePathname();
  const isActive = pathname === href;
  
  const computedClassName = typeof className === "function" 
    ? className(isActive) 
    : className;

  return (
    <Link href={href} className={computedClassName} onClick={onClick}>
      {children}
    </Link>
  );
}