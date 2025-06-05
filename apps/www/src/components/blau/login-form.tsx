"use client";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { useAccount, useConnect } from "wagmi";
import { redirect } from "next/navigation";
import { useEffect } from "react";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

export function LoginForm({
  className,
  ...props
}: React.ComponentProps<"div">) {
  const { isConnected } = useAccount();
  const { connectors, connect } = useConnect();

  const login = async () => {
    const connector = connectors.find(
      (connector) => connector.id === "xyz.ithaca.porto"
    )!;
    connect({ connector });
  };

  const createAccount = async () => {
    const connector = connectors.find(
      (connector) => connector.id === "xyz.ithaca.porto"
    )!;
    connect({ connector });
  };
  useEffect(() => {
    if (isConnected) {
      redirect("/portfolio");
    }
  }, [isConnected]);

  return (
    <div className={cn("flex flex-col gap-6", className)} {...props}>
      <Card>
        <CardHeader>
          <CardTitle>Login to your account</CardTitle>
          <CardDescription>
            Click the button below to login to your account
          </CardDescription>
        </CardHeader>
        <CardContent>
          <form>
            <div className="flex flex-col gap-6">
              <div className="flex flex-col gap-2">
                <Label htmlFor="username">Username</Label>
                <Input
                  id="username"
                  placeholder="Enter your username"
                  type="text"
                  required
                />
              </div>

              <Button type="submit" className="w-full" onClick={createAccount}>
                Create Account
              </Button>
              <Separator />
              <Button type="submit" className="w-full" onClick={login}>
                Login
              </Button>
            </div>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}
