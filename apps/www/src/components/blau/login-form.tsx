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
import { useAccount, useConnect } from "wagmi";
import { redirect } from "next/navigation";
import { useEffect } from "react";
import { Input } from "@/components/ui/input";
import { zodResolver } from "@hookform/resolvers/zod";
import { useForm } from "react-hook-form";
import * as z from "zod";
import {
  Form,
  FormControl,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/components/ui/form";
import { Separator } from "../ui/separator";
import { Loader2 } from "lucide-react";

const createAccountSchema = z.object({
  username: z.string().min(3, "Username must be at least 3 characters"),
});

const loginSchema = z.object({});

type CreateAccountForm = z.infer<typeof createAccountSchema>;
type LoginForm = z.infer<typeof loginSchema>;

export function LoginForm({
  className,
  ...props
}: React.ComponentProps<"div">) {
  const { isConnected } = useAccount();
  const { connectors, connect, isPending } = useConnect();

  const createAccountForm = useForm<CreateAccountForm>({
    resolver: zodResolver(createAccountSchema),
  });

  const loginForm = useForm<LoginForm>({
    resolver: zodResolver(loginSchema),
  });

  const onLogin = async () => {
    console.log("Logging in");
    const connector = connectors.find(
      (connector) => connector.id === "xyz.ithaca.porto"
    )!;
    connect({ connector });
  };

  const onCreateAccount = async (data: CreateAccountForm) => {
    console.log("Creating account with username:", data.username);
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
          <CardTitle>Create Account</CardTitle>
          <CardDescription>
            Enter your username to create a new account
          </CardDescription>
        </CardHeader>
        <CardContent>
          <Form {...createAccountForm}>
            <form onSubmit={createAccountForm.handleSubmit(onCreateAccount)}>
              <div className="flex flex-col gap-6">
                <FormField
                  control={createAccountForm.control}
                  name="username"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Username</FormLabel>
                      <FormControl>
                        <Input placeholder="Enter your username" {...field} />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                <Button type="submit" className="w-full" disabled={isPending}>
                  {isPending ? (
                    <>
                      <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                      Creating Account...
                    </>
                  ) : (
                    "Create Account"
                  )}
                </Button>
              </div>
            </form>
          </Form>

          <div className="flex items-center gap-4 my-4">
            <Separator className="flex-1" />
            <span className="text-sm text-muted-foreground">or</span>
            <Separator className="flex-1" />
          </div>

          <Form {...loginForm}>
            <form onSubmit={loginForm.handleSubmit(onLogin)}>
              <div className="flex flex-col gap-6">
                <Button type="submit" className="w-full" disabled={isPending}>
                  {isPending ? (
                    <>
                      <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                      Logging in...
                    </>
                  ) : (
                    "Login"
                  )}
                </Button>
              </div>
            </form>
          </Form>
        </CardContent>
      </Card>
    </div>
  );
}
