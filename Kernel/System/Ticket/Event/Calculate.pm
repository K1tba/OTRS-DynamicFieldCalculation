# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Kernel::System::Ticket::Event::Calculate;

use strict;
use warnings;

use Math::Expression;

use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::DynamicField',
    'Kernel::System::DynamicFieldValue',
    'Kernel::System::DynamicField::Backend',
    'Kernel::System::Log',
    'Kernel::System::Ticket',
);

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(Data Event Config UserID)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );
            return;
        }
    }

    # listen to all kinds of events
    if ( !$Param{Data}->{TicketID} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Need TicketID in Data!",
        );
        return;
    }

    # get config object
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # get ticket object
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');

    my %Ticket = $Kernel::OM->Get('Kernel::System::Ticket')->TicketGet(
        TicketID      => $Param{Data}->{TicketID},
        UserID        => $Param{UserID},
        DynamicFields => 1,
    );

    return if !%Ticket;

    # get dynamic field objects
    my $DynamicFieldObject        = $Kernel::OM->Get('Kernel::System::DynamicField');
    my $DynamicFieldValueObject   = $Kernel::OM->Get('Kernel::System::DynamicFieldValue');
    my $DynamicFieldBackendObject = $Kernel::OM->Get('Kernel::System::DynamicField::Backend');

    # get dynamic fields list
    my $DynamicFieldList = $DynamicFieldObject->DynamicFieldList(
        ObjectType => 'Ticket',
        FieldType  => 'Calculation',
    );

    my $MathExpr = Math::Expression->new( PrintErrFunc => sub {} );

    FIELD:
    for my $FieldID ( @{ $DynamicFieldList } ) {

        my $DynamicField = $DynamicFieldObject->DynamicFieldGet(
            ID => $FieldID,
        );

        my $ExpressionString = $DynamicField->{Config}->{CalculationFormula} || '';
        next FIELD if !$ExpressionString;

        # get tags <OTRS_TICKET_DynamicField_*> or <OTRS_TICKET_AccountedTime> from a string
        my @Matches = $ExpressionString =~ /<OTRS_TICKET_(\w+)>/g;

        my @MatchesFound = grep { $Ticket{$_} } @Matches;
        next FIELD if !@MatchesFound;

        for my $FieldName ( @Matches ) {

            my $Result = 0;

            if ( $FieldName =~ /^DynamicField_(\w+)$/ ) {

                $Param{DFName} = $1;
                my $DynamicField = $DynamicFieldObject->DynamicFieldGet(
                    Name => $Param{DFName},
                );

                if ( !$DynamicField || !IsHashRefWithData( $DynamicField ) ) {
                    $Kernel::OM->Get('Kernel::System::Log')->Log(
                        Priority => 'error',
                        Message  => "Not a valid arithmetic expression for '$DynamicField->->{Name}'"
                            . " dynamic field: The formula refers a non-existent dynamic field '$Param{DFName}'!",
                    );
                    return;
                }

                my $Value = $DynamicFieldValueObject->ValueGet(
                    FieldID  => $DynamicField->{ID},
                    ObjectID => $Ticket{TicketID},
                );
                
                if (
                    $Value
                    && IsArrayRefWithData($Value)
                    && IsHashRefWithData($Value->[0])
                    )
                {
                    $Result = sprintf("%.2f", $Value->[0]->{ValueText});
                }
                elsif ( $DynamicField->{Config}->{DefaultValue} ) {
                    $Result = $DynamicField->{Config}->{DefaultValue};
                }
            }
            elsif ( $FieldName eq 'AccountedTime' ) {
                $Result = $TicketObject->TicketAccountedTimeGet(
                    TicketID => $Ticket{TicketID},
                );
            }

            $ExpressionString =~ s{<OTRS_TICKET_$FieldName>}{$Result}xsmg;
        }

        my $DFValue = $MathExpr->EvalToScalar(
            $MathExpr->Parse( $ExpressionString )
        );

        # set the value
        my $Success = $DynamicFieldBackendObject->ValueSet(
            DynamicFieldConfig => $DynamicField,
            ObjectID           => $Param{Data}->{TicketID},
            Value              => $DFValue || 0,
            UserID             => $Param{UserID},
        );

        if ( !$Success ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message =>
                    "Can not set value $DFValue for dynamic field $DynamicField->{Name}!"
            );
        }
    }

    return 1;
}

1;
