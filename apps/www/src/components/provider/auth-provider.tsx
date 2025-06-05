"use client";

import { redirect } from "next/navigation";
import { useAccount } from "wagmi";

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const { isConnected } = useAccount();

  if (!isConnected) {
    redirect("/login");
  }

  return <>{children}</>;
}
