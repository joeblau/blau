import { LoginForm } from "@/components/blau/login-form";
import { ModeToggle } from "@/components/blau-ui/mode-toggle";
import Link from "next/link";
import { Button } from "@/components/ui/button";
import { HomeIcon } from "lucide-react";

export default function LoginPage() {
  return (
    <div className="relative flex min-h-svh w-full items-center justify-center p-6 md:p-10">
      <div className="absolute left-6 top-6 md:left-10 md:top-10">
        <Button variant="outline" size="icon" asChild>
          <Link href="/">
            <HomeIcon className="h-4 w-4" />
          </Link>
        </Button>
      </div>
      <div className="absolute right-6 top-6 md:right-10 md:top-10">
        <ModeToggle />
      </div>
      <div className="w-full max-w-sm">
        <LoginForm />
      </div>
    </div>
  );
}
