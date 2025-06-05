import { AuthProvider } from "@/components/provider/auth-provider";

export default function DappLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return <AuthProvider>{children}</AuthProvider>;
}
