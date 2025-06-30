import { Suspense } from "react";
import { CreateDashboard } from "../routes/CreateDashboard";
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Create",
  description: "Create new proposals or DAOs on Govex. Launch your own futarchy markets and participate in decentralized governance on Sui.",
  keywords: ["create DAO", "create proposal", "futarchy", "governance", "Sui", "Govex"],
  openGraph: {
    title: "Create - Govex",
    description: "Create new proposals or DAOs on Govex. Launch your own futarchy markets and participate in decentralized governance on Sui.",
    type: "website",
  },
  twitter: {
    title: "Create - Govex",
    description: "Create new proposals or DAOs on Govex. Launch your own futarchy markets and participate in decentralized governance on Sui.",
  },
};

export default function CreatePage() {
  return (
    <Suspense fallback={<div>Loading...</div>}>
      <CreateDashboard />
    </Suspense>
  );
}