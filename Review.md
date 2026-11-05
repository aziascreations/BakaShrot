
Ignore for the time being

# Rules

## ???
Any structure related to networking cannot use the `.i` data type.
Any use of this type in those should fail the review.

## ???
Any enumerations related to networking must declare its values explicitely.
Not doing this can cause parsing failures.
Any missing value should fail the review.
