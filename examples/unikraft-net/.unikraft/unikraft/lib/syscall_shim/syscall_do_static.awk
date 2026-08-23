BEGIN {
	max_args = 6
	print "/* Auto generated file. DO NOT EDIT */\n\n"
}

/[a-zA-Z0-9]+-[0-9]+e?/ {
	name = $1
	args_nr = $2 + 0

	printf "\n/* SYS_%s: %d argument(s) */\n", name, args_nr;
	for (i = 0; i <= max_args; i++)
	{
		if (substr($0, length($0)) == "e") {
			printf "#define uk_syscall_do%d_e_%s(", i, name;
			for (j = 1; j <= i; j++)
			{
				if (j > 1)
					printf ", "
				printf "arg%d", j;
			}
			printf ") \\\n";

			printf "\tuk_syscall_do_e_%s(", name;

			# hand-over given arguments
			for (j = 1; j <= i && j <= args_nr; j++)
			{
				if (j > 1)
					printf ", "
				printf "__uk_scc(arg%d)", j;
			}

			# fill-up missing arguments
			for (j = i + 1; j <= args_nr; j++)
			{
				if (j > 1)
					printf ", "
				printf "__uk_scc(0)";
			}
			printf ")\n";
		}

		printf "#define uk_syscall_do%d_%s(", i, name;
		for (j = 1; j <= i; j++)
		{
			if (j > 1)
				printf ", "
			printf "arg%d", j;
		}
		printf ") \\\n";

		printf "\tuk_syscall_do_%s(", name;

		# hand-over given arguments
		for (j = 1; j <= i && j <= args_nr; j++)
		{
			if (j > 1)
				printf ", "
			printf "__uk_scc(arg%d)", j;
		}

		# fill-up missing arguments
		for (j = i + 1; j <= args_nr; j++)
		{
			if (j > 1)
				printf ", "
			printf "__uk_scc(0)";
		}
		printf ")\n";
	}
}
